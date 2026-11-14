#!/bin/bash

# ============================================================================
# refresh-vendor.sh: the image's PHP libraries reach sites already installed
# ============================================================================
# Gibbon and Moodle copy their code, vendor/ included, onto the site's volume
# at install, and again only when the app's version changes. A rebuilt image
# with newer libraries for the same app version (4.5.6: twig and
# phpspreadsheet for Gibbon, jmespath.php for Moodle) would leave every
# existing site on the old ones. installer/refresh-vendor.sh, the same file in
# both images, runs from the entrypoint before Apache starts and replaces the
# site's vendor/ with the image's when the site runs the image's app version
# and its vendor/ is one a Clouve image put there. This test runs both copies
# as root in php:8.3-apache (the images' base) with no network, on made-up
# packages and sites, and checks that:
#   - --id gives the same id to two package lists with the same packages in
#     any order and layout, a different id when a version differs, and none
#     for a missing, unreadable or linked list;
#   - a site on upstream's vendor/ gets the image's, with composer.json and
#     composer.lock, all www-data's, the marker recording it, one log line,
#     and no vendor.clouve-* folder left;
#   - a site already on the image's vendor/ only gets the marker;
#   - a vendor/ whose package list someone changed, or with a package's file
#     edited, added in place of a listed one or taken away, is left alone and
#     logged once, packages under vendor/composer/ (composer/pcre) included
#     (the files Composer writes itself, directly in vendor/composer/, in
#     vendor/bin/ and vendor/autoload.php, aren't compared, and files no package
#     ships go with the old tree); one the marker recorded for this app version,
#     with the file list the marker keeps, is replaced;
#   - a site on another app version is skipped without a word (Gibbon's
#     version string, Moodle's $version in public/version.php);
#   - a start cut off between the two renames is finished by the next one,
#     one cut off after them still gets the image's composer.json and
#     composer.lock, and a leftover vendor.clouve-new from a cut-off copy is
#     cleared first; one that can't be cleared stops the refresh;
#   - links a tenant could leave at vendor.clouve-new, vendor.clouve-old,
#     composer.lock, the marker, the state folder or the site's clouve/ folder
#     never make root write or delete outside the site, a hard link at
#     composer.lock leaves the file it shares unchanged, a pipe in place of a
#     file never hangs the start, and a linked vendor/ is left as it is;
#   - a copy that runs out of space keeps the old vendor/ and lets the
#     container start (exit 0);
#   - every log line starts with [clouve-vendor] and names no path on the site;
#   - the two copies of the script are the same file, and each entrypoint
#     calls it.
#
# Needs Docker (php:8.3-apache, pulled when missing).
#
# Usage: bash tests/vendor-refresh.test.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_IMAGE="php:8.3-apache"
GIBBON_SCRIPT="$REPO_DIR/apps/gibbon/image/installer/refresh-vendor.sh"
MOODLE_SCRIPT="$REPO_DIR/apps/moodle/image/installer/refresh-vendor.sh"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'
FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi

echo "The script and its callers"
for s in "$GIBBON_SCRIPT" "$MOODLE_SCRIPT"; do
  if [ -f "$s" ]; then pass "${s#"$REPO_DIR"/} exists"; else fail "${s#"$REPO_DIR"/} exists"; fi
done
if [ -f "$GIBBON_SCRIPT" ] && [ -f "$MOODLE_SCRIPT" ] && cmp -s "$GIBBON_SCRIPT" "$MOODLE_SCRIPT"; then
  pass "Gibbon's and Moodle's copies are the same file"
else
  fail "Gibbon's and Moodle's copies are the same file"
fi
if grep -qxF '"$GIBBON_PACKAGE_INSTALLER"/refresh-vendor.sh gibbon "$GIBBON_PACKAGE_PATH" "$GIBBON_INSTALL_PATH" "$INSTALLED_VERSIONS_PATH"' \
    "$REPO_DIR/apps/gibbon/image/installer/entrypoint.sh"; then
  pass "Gibbon's entrypoint calls it"
else
  fail "Gibbon's entrypoint calls it"
fi
if grep -qxF '"$MOODLE_PACKAGE_INSTALLER"/refresh-vendor.sh moodle "$MOODLE_PACKAGE_PATH" "$MOODLE_INSTALL_PATH" "$INSTALLED_VERSIONS_PATH"' \
    "$REPO_DIR/apps/moodle/image/installer/entrypoint.sh"; then
  pass "Moodle's entrypoint calls it"
else
  fail "Moodle's entrypoint calls it"
fi
if [ ! -f "$GIBBON_SCRIPT" ] || [ ! -f "$MOODLE_SCRIPT" ]; then
  printf '\n%sThe script is missing; the cases below need it.%s\n' "$RED" "$RESET"
  exit 1
fi

WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # the EXIT trap runs it
cleanup() {
  # Files the container made are root's: remove them from inside one.
  docker run --rm --network none -v "$WORK:/w" --entrypoint rm "$BASE_IMAGE" -rf /w/t >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/t"
cp "$GIBBON_SCRIPT" "$WORK/t/refresh-gibbon.sh"
cp "$MOODLE_SCRIPT" "$WORK/t/refresh-moodle.sh"

# The cases run inside the container, as root, and print PASS and FAIL lines.
cat > "$WORK/t/cases.sh" <<'INNER'
#!/bin/bash
set -uo pipefail
T=/w/t
G="$T/refresh-gibbon.sh"
M="$T/refresh-moodle.sh"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=1; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# installed NAME:VERSION...: composer 2's installed.json on stdout.
installed() {
  local first=1 p
  printf '{\n    "packages": [\n'
  for p in "$@"; do
    [ "$first" = 1 ] || printf ',\n'
    first=0
    printf '        {\n            "name": "%s",\n            "version": "%s",\n            "type": "library"\n        }' "${p%%:*}" "${p#*:}"
  done
  printf '\n    ],\n    "dev": false,\n    "dev-package-names": []\n}\n'
}
UPSTREAM=(twig/twig:v3.11.3 phpoffice/phpspreadsheet:1.30.0 psr/log:1.1.4)
IMAGE=(twig/twig:v3.30.0 phpoffice/phpspreadsheet:1.30.7 psr/log:1.1.4)

# vendor_tree DIR TAG PACKAGES...: a vendor/ with a package list and a file that says which tree it is.
vendor_tree() {
  local dir="$1" tag="$2"
  shift 2
  mkdir -p "$dir/composer/pcre/src" "$dir/twig" "$dir/bin"
  installed "$@" > "$dir/composer/installed.json"
  echo "$tag" > "$dir/twig/TREE"
  echo "<?php // $tag" > "$dir/twig/Environment.php"
  # composer/pcre is a real package that lives under vendor/composer/, beside Composer's own files.
  echo "<?php // pcre of $tag" > "$dir/composer/pcre/src/Preg.php"
  echo "<?php // autoloader of $tag" > "$dir/composer/autoload_real.php"
  echo "<?php // $tag" > "$dir/autoload.php"
  echo "#!/usr/bin/env php $tag" > "$dir/bin/tool"
}

# gibbon_case NAME: a fresh package (the image) and site (the volume) for Gibbon 30.0.01, the site on upstream's vendor.
gibbon_case() {
  C="$T/$1"
  PKG="$C/clouve/gibbon/gibbon-30.0.01"
  SITE="$C/site"
  STATE="$SITE/clouve/installed"
  LOG="$C/log"
  mkdir -p "$PKG" "$STATE"
  printf "<?php\n\$version = '30.0.01';\n" > "$PKG/version.php"
  cp "$PKG/version.php" "$SITE/version.php"
  vendor_tree "$PKG/vendor" image "${IMAGE[@]}"
  echo '{"name":"gibbonedu/core","image":true}' > "$PKG/composer.json"
  echo '{"image-lock":true}' > "$PKG/composer.lock"
  vendor_tree "$SITE/vendor" upstream "${UPSTREAM[@]}"
  echo '{"name":"gibbonedu/core"}' > "$SITE/composer.json"
  echo '{"upstream-lock":true}' > "$SITE/composer.lock"
  vendor_tree "$C/upstream-vendor" upstream "${UPSTREAM[@]}"
  bash "$G" --id "$C/upstream-vendor" > "$C/clouve/gibbon/vendor-upstream.id"
  bash "$G" --sums "$C/upstream-vendor" > "$C/clouve/gibbon/vendor-upstream.sums"
  chown -R www-data:www-data "$SITE"
}
run_gibbon() { bash "$G" gibbon "$PKG" "$SITE" "$STATE" > "$LOG" 2>&1; RC=$?; }
tree() { cat "$SITE/vendor/twig/TREE" 2>/dev/null; }

echo "ids"
mkdir -p "$T/ids/a/composer" "$T/ids/b/composer" "$T/ids/c/composer" "$T/ids/d/composer" "$T/ids/e/composer"
installed twig/twig:v3.30.0 psr/log:1.1.4 > "$T/ids/a/composer/installed.json"
printf '[{"version":"1.1.4","name":"psr/log","extra":1},{"name":"twig/twig","version":"v3.30.0"}]' \
  > "$T/ids/b/composer/installed.json"
installed twig/twig:v3.27.0 psr/log:1.1.4 > "$T/ids/c/composer/installed.json"
echo 'not json' > "$T/ids/d/composer/installed.json"
ln -s "$T/ids/a/composer/installed.json" "$T/ids/e/composer/installed.json"
A="$(bash "$G" --id "$T/ids/a")"
check "an id is 64 hex characters" '[[ "$A" =~ ^[0-9a-f]{64}$ ]]'
check "the same packages in another order and layout give the same id" '[ "$A" = "$(bash "$G" --id "$T/ids/b")" ]'
check "another version gives another id" '[ "$A" != "$(bash "$G" --id "$T/ids/c")" ]'
check "a list that isn't JSON gives none" '! bash "$G" --id "$T/ids/d" >/dev/null 2>&1'
check "a missing list gives none" '! bash "$G" --id "$T/ids/none" >/dev/null 2>&1'
check "a linked list gives none" '! bash "$G" --id "$T/ids/e" >/dev/null 2>&1'

echo "upstream's vendor/ is replaced"
gibbon_case upstream
IMAGE_ID="$(bash "$G" --id "$PKG/vendor")"
run_gibbon
check "exits 0" '[ "$RC" = 0 ]'
check "the site has the image's vendor/" '[ "$(tree)" = image ]'
check "its package list is the image's" 'cmp -s "$PKG/vendor/composer/installed.json" "$SITE/vendor/composer/installed.json"'
check "composer.json and composer.lock are the image's" \
  'cmp -s "$PKG/composer.json" "$SITE/composer.json" && cmp -s "$PKG/composer.lock" "$SITE/composer.lock"'
check "vendor/ is www-data's throughout" '[ -z "$(find "$SITE/vendor" ! -user www-data)" ]'
check "composer.lock is www-data's" '[ "$(stat -c %U "$SITE/composer.lock")" = www-data ]'
check "the marker records the version and the id" '[ "$(cat "$STATE/vendor-id")" = "30.0.01 $IMAGE_ID" ]'
check "the marker keeps the image's file list" 'cmp -s "$STATE/vendor-sums" <(bash "$G" --sums "$PKG/vendor")'
check "no vendor.clouve-* is left" '[ -z "$(find "$SITE" -maxdepth 1 -name "vendor.clouve-*")" ]'
check "one log line says so" '[ "$(cat "$LOG")" = "[clouve-vendor] vendor/ now has the image'"'"'s libraries" ]'
run_gibbon
check "a second start changes nothing and says nothing" '[ "$RC" = 0 ] && [ ! -s "$LOG" ] && [ "$(tree)" = image ]'

echo "a site already on the image's vendor/"
gibbon_case current
rm -rf "$SITE/vendor"
cp -a "$PKG/vendor" "$SITE/vendor"
echo keep > "$SITE/vendor/KEEP"
run_gibbon
check "exits 0, says nothing" '[ "$RC" = 0 ] && [ ! -s "$LOG" ]'
check "vendor/ isn't copied again" '[ -f "$SITE/vendor/KEEP" ]'
check "the marker is written" '[ "$(cut -d" " -f1 "$STATE/vendor-id")" = 30.0.01 ]'

echo "a vendor/ someone changed"
gibbon_case changed
vendor_tree "$SITE/vendor" custom "${UPSTREAM[@]}" acme/extra:1.0.0
run_gibbon
check "exits 0" '[ "$RC" = 0 ]'
check "vendor/ is left as it is" '[ "$(tree)" = custom ]'
check "no marker" '[ ! -e "$STATE/vendor-id" ]'
check "one log line says so" \
  '[ "$(cat "$LOG")" = "[clouve-vendor] vendor/ on this site was changed after Clouve'"'"'s image put it there, so it was left as it is" ]'

changed_line="[clouve-vendor] vendor/ on this site was changed after Clouve's image put it there, so it was left as it is"
gibbon_case edited
echo "<?php // patched by hand" > "$SITE/vendor/twig/Environment.php"
run_gibbon
check "a package's file edited in place (the package list unchanged): left as it is" \
  '[ "$RC" = 0 ] && [ "$(cat "$SITE/vendor/twig/Environment.php")" = "<?php // patched by hand" ] && [ "$(tree)" = upstream ]'
check "and logged once, with no marker" '[ "$(cat "$LOG")" = "$changed_line" ] && [ ! -e "$STATE/vendor-id" ]'
gibbon_case missing-file
rm "$SITE/vendor/twig/Environment.php"
run_gibbon
check "a package's file taken away: left as it is" '[ "$RC" = 0 ] && [ "$(tree)" = upstream ] && [ "$(cat "$LOG")" = "$changed_line" ]'
gibbon_case no-list
rm "$SITE/vendor/composer/installed.json"
run_gibbon
check "a vendor/ with no package list: left as it is" '[ "$RC" = 0 ] && [ "$(tree)" = upstream ] && [ "$(cat "$LOG")" = "$changed_line" ]'
gibbon_case composer-package
echo "<?php // patched by hand" > "$SITE/vendor/composer/pcre/src/Preg.php"
run_gibbon
check "a file of a package under vendor/composer/ edited in place: left as it is" \
  '[ "$RC" = 0 ] && [ "$(cat "$SITE/vendor/composer/pcre/src/Preg.php")" = "<?php // patched by hand" ] && [ "$(cat "$LOG")" = "$changed_line" ]'
gibbon_case composer-own
echo "<?php // regenerated" > "$SITE/vendor/composer/autoload_real.php"
echo "<?php // regenerated" > "$SITE/vendor/autoload.php"
echo "#!/usr/bin/env php regenerated" > "$SITE/vendor/bin/tool"
echo "left from an older Gibbon" > "$SITE/vendor/twig/OLD.php"
run_gibbon
check "Composer's own files and a file no package ships aren't compared: replaced" '[ "$RC" = 0 ] && [ "$(tree)" = image ]'

echo "a vendor/ the marker recorded"
gibbon_case recorded
vendor_tree "$SITE/vendor" earlier-image twig/twig:v3.28.0 phpoffice/phpspreadsheet:1.30.6 psr/log:1.1.4
echo "30.0.01 $(bash "$G" --id "$SITE/vendor")" > "$STATE/vendor-id"
bash "$G" --sums "$SITE/vendor" > "$STATE/vendor-sums"
run_gibbon
check "is replaced" '[ "$RC" = 0 ] && [ "$(tree)" = image ]'
gibbon_case recorded-edited
vendor_tree "$SITE/vendor" earlier-image twig/twig:v3.28.0 phpoffice/phpspreadsheet:1.30.6 psr/log:1.1.4
echo "30.0.01 $(bash "$G" --id "$SITE/vendor")" > "$STATE/vendor-id"
bash "$G" --sums "$SITE/vendor" > "$STATE/vendor-sums"
echo "<?php // patched by hand" > "$SITE/vendor/twig/Environment.php"
run_gibbon
check "recorded, then a file edited in place: left as it is" '[ "$RC" = 0 ] && [ "$(tree)" = earlier-image ] && [ "$(cat "$LOG")" = "$changed_line" ]'
gibbon_case recorded-no-sums
vendor_tree "$SITE/vendor" earlier-image twig/twig:v3.28.0 phpoffice/phpspreadsheet:1.30.6 psr/log:1.1.4
echo "30.0.01 $(bash "$G" --id "$SITE/vendor")" > "$STATE/vendor-id"
run_gibbon
check "recorded with no file list: left as it is" '[ "$RC" = 0 ] && [ "$(tree)" = earlier-image ] && [ "$(cat "$LOG")" = "$changed_line" ]'
gibbon_case recorded-other
vendor_tree "$SITE/vendor" earlier-image twig/twig:v3.28.0 phpoffice/phpspreadsheet:1.30.6 psr/log:1.1.4
echo "30.0.00 $(bash "$G" --id "$SITE/vendor")" > "$STATE/vendor-id"
run_gibbon
check "recorded for another version: left as it is" '[ "$RC" = 0 ] && [ "$(tree)" = earlier-image ]'

echo "a site on another version"
gibbon_case other-version
printf "<?php\n\$version = '30.0.02';\n" > "$SITE/version.php"
run_gibbon
check "is skipped without a word" '[ "$RC" = 0 ] && [ ! -s "$LOG" ] && [ "$(tree)" = upstream ] && [ ! -e "$STATE/vendor-id" ]'

echo "Moodle"
moodle_case() {
  C="$T/$1"
  PKG="$C/clouve/moodle/moodle-5.3"
  SITE="$C/site"
  STATE="$SITE/clouve/installed"
  LOG="$C/log"
  mkdir -p "$PKG/public" "$SITE/public" "$STATE"
  printf '<?php\n$version  = 2026100500.00;          // YYYYMMDD\n' > "$PKG/public/version.php"
  printf '<?php\n$version  = %s;          // YYYYMMDD\n' "$2" > "$SITE/public/version.php"
  vendor_tree "$PKG/vendor" image mtdowling/jmespath.php:2.9.2 aws/aws-sdk-php:3.356.22
  echo '{"m":"image"}' > "$PKG/composer.json"
  echo '{"m":"image-lock"}' > "$PKG/composer.lock"
  vendor_tree "$SITE/vendor" upstream mtdowling/jmespath.php:2.8.0 aws/aws-sdk-php:3.356.22
  vendor_tree "$C/upstream-vendor" upstream mtdowling/jmespath.php:2.8.0 aws/aws-sdk-php:3.356.22
  bash "$M" --id "$C/upstream-vendor" > "$C/clouve/moodle/vendor-upstream.id"
  bash "$M" --sums "$C/upstream-vendor" > "$C/clouve/moodle/vendor-upstream.sums"
}
run_moodle() { bash "$M" moodle "$PKG" "$SITE" "$STATE" > "$LOG" 2>&1; RC=$?; }
moodle_case moodle-same 2026100500.00
run_moodle
check "a site on the image's \$version gets the image's vendor/" '[ "$RC" = 0 ] && [ "$(tree)" = image ]'
check "the marker records Moodle's \$version" '[ "$(cut -d" " -f1 "$STATE/vendor-id")" = 2026100500 ]'
moodle_case moodle-older 2025100600.00
run_moodle
check "a site on an older \$version is skipped" '[ "$RC" = 0 ] && [ ! -s "$LOG" ] && [ "$(tree)" = upstream ]'
moodle_case moodle-linked-public 2026100500.00
mkdir -p "$C/elsewhere"
mv "$SITE/public/version.php" "$C/elsewhere/version.php"
rm -rf "$SITE/public"
ln -s "$C/elsewhere" "$SITE/public"
run_moodle
check "a linked public/ isn't read through: skipped without a word" '[ "$RC" = 0 ] && [ ! -s "$LOG" ] && [ "$(tree)" = upstream ]'

echo "a start cut off"
gibbon_case cut-between
mv "$SITE/vendor" "$SITE/vendor.clouve-old"
cp -a "$PKG/vendor" "$SITE/vendor.clouve-new"
run_gibbon
check "between the renames: the next start finishes the swap" \
  '[ "$RC" = 0 ] && [ "$(tree)" = image ] && [ -z "$(find "$SITE" -maxdepth 1 -name "vendor.clouve-*")" ]'
check "and records it" '[ "$(cut -d" " -f1 "$STATE/vendor-id")" = 30.0.01 ]'
check "and copies the image's composer.json and composer.lock" \
  'cmp -s "$PKG/composer.json" "$SITE/composer.json" && cmp -s "$PKG/composer.lock" "$SITE/composer.lock"'
gibbon_case cut-after
mv "$SITE/vendor" "$SITE/vendor.clouve-old"
cp -a "$PKG/vendor" "$SITE/vendor"
run_gibbon
check "after the renames (the old tree still there, no marker): the composer files are the image's" \
  '[ "$RC" = 0 ] && cmp -s "$PKG/composer.lock" "$SITE/composer.lock" && cmp -s "$PKG/composer.json" "$SITE/composer.json"'
check "the old tree is gone and the marker written" \
  '[ -z "$(find "$SITE" -maxdepth 1 -name "vendor.clouve-*")" ] && [ "$(cut -d" " -f1 "$STATE/vendor-id")" = 30.0.01 ]'
gibbon_case cut-copy
mkdir -p "$SITE/vendor.clouve-new/twig"
echo partial > "$SITE/vendor.clouve-new/twig/TREE"
run_gibbon
check "during the copy: the leftover is cleared and the refresh runs" \
  '[ "$RC" = 0 ] && [ "$(tree)" = image ] && [ -z "$(find "$SITE" -maxdepth 1 -name "vendor.clouve-*")" ]'

echo "links a tenant could leave"
gibbon_case links
OUT="$C/outside"
mkdir -p "$OUT/dir"
echo sentinel > "$OUT/dir/SENTINEL"
echo original > "$OUT/file"
echo original > "$OUT/marker"
ln -s "$OUT/dir" "$SITE/vendor.clouve-new"
ln -s "$OUT/dir" "$SITE/vendor.clouve-old"
rm -f "$SITE/composer.lock"
ln -s "$OUT/file" "$SITE/composer.lock"
ln -s "$OUT/marker" "$STATE/vendor-id"
run_gibbon
check "the refresh still runs" '[ "$RC" = 0 ] && [ "$(tree)" = image ]'
check "nothing is written into or deleted from the folder the links named" '[ "$(ls -A "$OUT/dir")" = SENTINEL ]'
check "the file composer.lock linked to is unchanged" '[ "$(cat "$OUT/file")" = original ]'
check "composer.lock is now a file of its own" '[ ! -L "$SITE/composer.lock" ] && cmp -s "$PKG/composer.lock" "$SITE/composer.lock"'
check "the file the marker linked to is unchanged" '[ "$(cat "$OUT/marker")" = original ]'
check "the marker is now a file of its own" '[ ! -L "$STATE/vendor-id" ] && [ "$(cut -d" " -f1 "$STATE/vendor-id")" = 30.0.01 ]'
gibbon_case linked-state
OUT="$C/outside"
mkdir -p "$OUT"
rm -rf "$STATE"
ln -s "$OUT" "$STATE"
run_gibbon
check "a linked state folder: nothing is written outside the site" '[ "$RC" = 0 ] && [ -z "$(ls -A "$OUT")" ]'
gibbon_case linked-clouve
OUT="$C/outside"
mkdir -p "$OUT/installed"
rm -rf "$SITE/clouve"
ln -s "$OUT" "$SITE/clouve"
run_gibbon
check "a linked clouve/ folder (the state folder's parent): nothing is written outside the site" \
  '[ "$RC" = 0 ] && [ -z "$(ls -A "$OUT/installed")" ] && [ "$(tree)" = upstream ]'
check "and logged once" \
  '[ "$(cat "$LOG")" = "[clouve-vendor] the site'"'"'s state folder isn'"'"'t a folder of its own, so vendor/ was left as it is" ]'
gibbon_case hardlink
echo "the tenant's own file" > "$SITE/notes.txt"
rm -f "$SITE/composer.lock"
ln "$SITE/notes.txt" "$SITE/composer.lock"
run_gibbon
check "a hard link at composer.lock: the file it shared is unchanged" \
  '[ "$RC" = 0 ] && [ "$(cat "$SITE/notes.txt")" = "the tenant'"'"'s own file" ] && cmp -s "$PKG/composer.lock" "$SITE/composer.lock"'
for f in vendor/composer/installed.json version.php clouve/installed/vendor-id; do
  gibbon_case "fifo-${f//\//-}"
  rm -f "$SITE/$f"
  mkfifo "$SITE/$f"
  timeout 30 bash "$G" gibbon "$PKG" "$SITE" "$STATE" > "$LOG" 2>&1
  RC=$?
  check "a pipe at $f doesn't hang the start" '[ "$RC" != 124 ]'
  check "a pipe at $f: vendor/ is left or refreshed, never half" '[ "$RC" = 0 ] && { [ "$(tree)" = upstream ] || [ "$(tree)" = image ]; }'
done
gibbon_case linked-vendor
OUT="$C/outside"
mv "$SITE/vendor" "$OUT"
ln -s "$OUT" "$SITE/vendor"
run_gibbon
check "a linked vendor/ is left as it is" '[ "$RC" = 0 ] && [ -L "$SITE/vendor" ] && [ "$(cat "$OUT/twig/TREE")" = upstream ]'
check "and logged once" '[ "$(cat "$LOG")" = "[clouve-vendor] vendor/ on this site isn'"'"'t a folder, so it was left as it is" ]'

echo "a temp file an earlier start left in the state folder"
gibbon_case temp-left
echo leftover > "$STATE/.vendor.AbC123"
run_gibbon
check "is cleared, and the refresh runs" '[ "$RC" = 0 ] && [ "$(tree)" = image ] && [ ! -e "$STATE/.vendor.AbC123" ]'

echo "an image with no package list"
gibbon_case image-no-list
rm "$PKG/vendor/composer/installed.json"
run_gibbon
check "the site keeps its vendor/, and a FAILED line says why" \
  '[ "$RC" = 0 ] && [ "$(tree)" = upstream ] && grep -q "^\[clouve-vendor\] FAILED" "$LOG"'

echo "log lines"
check "each starts with [clouve-vendor]" '! grep -hv "^\[clouve-vendor\] " "$T"/*/log | grep -q .'
check "none names a path on the site" '! grep -q "/w/" "$T"/*/log'

exit "$FAILED"
INNER

# The out-of-space case: the site is a 1 MiB tmpfs and the image's vendor/ is bigger.
cat > "$WORK/t/space.sh" <<'INNER'
#!/bin/bash
set -uo pipefail
G=/w/t/refresh-gibbon.sh
PKG=/pkg/clouve/gibbon/gibbon-30.0.01
SITE=/site
mkdir -p "$PKG/vendor/composer" "$PKG/vendor/big" "$SITE/vendor/composer" "$SITE/vendor/twig" "$SITE/clouve/installed"
printf "<?php\n\$version = '30.0.01';\n" | tee "$PKG/version.php" > "$SITE/version.php"
echo '{"packages":[{"name":"twig/twig","version":"v3.30.0"}]}' > "$PKG/vendor/composer/installed.json"
head -c 3000000 /dev/zero > "$PKG/vendor/big/blob"
echo '{"packages":[{"name":"twig/twig","version":"v3.11.3"}]}' > "$SITE/vendor/composer/installed.json"
echo upstream > "$SITE/vendor/twig/TREE"
bash "$G" --id "$SITE/vendor" > /pkg/clouve/gibbon/vendor-upstream.id
bash "$G" --sums "$SITE/vendor" > /pkg/clouve/gibbon/vendor-upstream.sums
bash "$G" gibbon "$PKG" "$SITE" "$SITE/clouve/installed" > /tmp/log 2>&1
rc=$?
if [ "$rc" = 0 ]; then echo "PASS a copy out of space exits 0"; else echo "FAIL a copy out of space exits 0 (exit $rc)"; fi
if [ "$(cat "$SITE/vendor/twig/TREE")" = upstream ]; then echo "PASS the old vendor/ is kept"; else echo "FAIL the old vendor/ is kept"; fi
if [ -z "$(find "$SITE" -maxdepth 1 -name 'vendor.clouve-*')" ]; then echo "PASS the partial copy is removed"; else echo "FAIL the partial copy is removed"; fi
if grep -q '^\[clouve-vendor\] FAILED' /tmp/log; then echo "PASS a FAILED line is logged"; else echo "FAIL a FAILED line is logged"; fi
INNER

# A leftover vendor.clouve-new that can't be removed (here a mount point): the refresh stops, and nothing is copied
# into it (which would nest the image's tree a level down).
cat > "$WORK/t/busy.sh" <<'INNER'
#!/bin/bash
set -uo pipefail
G=/w/t/refresh-gibbon.sh
PKG=/pkg/clouve/gibbon/gibbon-30.0.01
SITE=/site
mkdir -p "$PKG/vendor/composer" "$PKG/vendor/twig" "$SITE/vendor/composer" "$SITE/vendor/twig" "$SITE/clouve/installed"
printf "<?php\n\$version = '30.0.01';\n" | tee "$PKG/version.php" > "$SITE/version.php"
echo '{"packages":[{"name":"twig/twig","version":"v3.30.0"}]}' > "$PKG/vendor/composer/installed.json"
echo image > "$PKG/vendor/twig/TREE"
echo '{"packages":[{"name":"twig/twig","version":"v3.11.3"}]}' > "$SITE/vendor/composer/installed.json"
echo upstream > "$SITE/vendor/twig/TREE"
bash "$G" --id "$SITE/vendor" > /pkg/clouve/gibbon/vendor-upstream.id
bash "$G" --sums "$SITE/vendor" > /pkg/clouve/gibbon/vendor-upstream.sums
bash "$G" gibbon "$PKG" "$SITE" "$SITE/clouve/installed" > /tmp/log 2>&1
rc=$?
if [ "$rc" = 0 ]; then echo "PASS a leftover that can't be removed: exits 0"; else echo "FAIL a leftover that can't be removed: exits 0 (exit $rc)"; fi
if [ "$(cat "$SITE/vendor/twig/TREE")" = upstream ]; then echo "PASS the old vendor/ is kept"; else echo "FAIL the old vendor/ is kept"; fi
if [ ! -e "$SITE/vendor.clouve-new/vendor" ]; then echo "PASS nothing is copied into the leftover"; else echo "FAIL nothing is copied into the leftover"; fi
if grep -q '^\[clouve-vendor\] FAILED' /tmp/log && ! grep -q '/site' /tmp/log; then echo "PASS a FAILED line, with no path, says why"; else echo "FAIL a FAILED line, with no path, says why"; fi
INNER

echo
echo "Cases (as root in $BASE_IMAGE, no network)"
out="$(docker run --rm --network none -v "$WORK:/w" --entrypoint bash "$BASE_IMAGE" /w/t/cases.sh 2>&1)"
rc=$?
out+=$'\n'"$(docker run --rm --network none -v "$WORK:/w:ro" --tmpfs /site:size=1m --tmpfs /pkg:size=8m \
  --entrypoint bash "$BASE_IMAGE" /w/t/space.sh 2>&1)"
out+=$'\n'"$(docker run --rm --network none -v "$WORK:/w:ro" --tmpfs /site --tmpfs /site/vendor.clouve-new --tmpfs /pkg \
  --entrypoint bash "$BASE_IMAGE" /w/t/busy.sh 2>&1)"
while IFS= read -r line; do
  case "$line" in
    "PASS "*) pass "${line#PASS }" ;;
    "FAIL "*) fail "${line#FAIL }" ;;
    "") ;;
    *) printf '    %s\n' "$line" ;;
  esac
done <<< "$out"
[ "$rc" -eq 0 ] || FAILED=1

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%srefresh-vendor checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%srefresh-vendor checks failed.%s\n' "$RED" "$RESET"
exit 1
