#!/bin/bash
# Puts the image's PHP libraries (vendor/) on a site that runs the image's app version.
#
# Gibbon and Moodle copy their code, vendor/ included, onto the site's volume at install, and again only when the
# app's version changes. When an image brings newer libraries for the same version, this script replaces the site's
# vendor/ with the image's. It does so only when the site's vendor/ is the one a Clouve image put there: its package
# list and every package file match upstream's tree for this version (the id and file list next to the package,
# written when the image was built), or the tree the marker in the state folder recorded for this version. A vendor/
# whose package list someone changed, or with a package's file edited, replaced or taken away, is left as it is, and
# one log line says so. That covers packages under vendor/composer/ too (composer/pcre, composer/ca-bundle). Only
# the files Composer writes itself (the ones directly in vendor/composer/, vendor/bin/, vendor/autoload.php) aren't
# compared, and files that no package ships (an older version's leftovers, a file someone added) go with the old
# tree.
#
# Usage:
#   refresh-vendor.sh --id VENDOR_DIR           prints the id of the libraries in VENDOR_DIR
#   refresh-vendor.sh --sums VENDOR_DIR         prints the sha256 list of VENDOR_DIR's package files
#   refresh-vendor.sh APP PACKAGE SITE STATE    APP is gibbon or moodle
#
# The entrypoint runs it as root before Apache, cron and the sshd start, so none of the tenant's code runs meanwhile.
# It never writes, deletes or hashes through a link on the site, and reads the site's version file only when no part
# of its path inside the site is a link. Its log lines name no path. A failure before the swap keeps the old
# vendor/ and exits 0, so the site starts as it was. A failure between the two renames exits 1, and the next start
# finishes the swap. Gibbon's and Moodle's copies of this file are the same (tests/vendor-refresh.test.sh).
set -u

log() { echo "[clouve-vendor] $*"; }

usage() {
  echo "Usage: refresh-vendor.sh --id VENDOR_DIR | --sums VENDOR_DIR | gibbon|moodle PACKAGE SITE STATE" >&2
  exit 2
}

# regular FILE: a file and not a link. The site's files are the tenant's, and reading a pipe or a device that a
# link points at could hang the start.
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }

# vendor_id DIR: the sha256 of the sorted "name version" lines in DIR/composer/installed.json. It hashes the
# packages, not the file, so two Composer versions that installed the same packages give the same id. Nothing,
# and status 1, for a list that is missing, linked, too big or not Composer's.
vendor_id() {
  local list="$1/composer/installed.json" lines
  { [ ! -L "$1" ] && [ ! -L "$1/composer" ] && regular "$list"; } || return 1
  [ "$(stat -c %s -- "$list" 2>/dev/null)" -le 16777216 ] 2>/dev/null || return 1
  lines="$(php -n -r '
    $d = json_decode((string) file_get_contents($argv[1]), true);
    if (!is_array($d)) exit(1);
    $p = array_key_exists("packages", $d) ? $d["packages"] : $d;
    if (!is_array($p) || count($p) === 0) exit(1);
    $out = [];
    foreach ($p as $x) {
      if (!is_array($x) || !isset($x["name"], $x["version"]) || !is_string($x["name"]) || !is_string($x["version"])) exit(1);
      $out[] = $x["name"] . " " . $x["version"];
    }
    sort($out, SORT_STRING);
    echo implode("\n", $out), "\n";
  ' -- "$list" 2>/dev/null)" || return 1
  [ -n "$lines" ] || return 1
  printf '%s\n' "$lines" | sha256sum | cut -c1-64
}

# vendor_sums DIR: "<sha256>  ./<path>" for every package file in DIR (a tree of Clouve's image), sorted. What
# Composer writes itself is left out, since it regenerates those files on every install: the files directly in
# vendor/composer/ (never its subfolders, which are packages), vendor/bin/ and vendor/autoload.php.
vendor_sums() {
  (cd "$1" 2>/dev/null && find . -type f ! -regex '\./composer/[^/]*' ! -path './bin/*' ! -path ./autoload.php -print0 |
    LC_ALL=C sort -z | xargs -0 -r sha256sum) || return 1
}

# tree_matches SUMS DIR: status 0 when every file SUMS lists is a regular file inside DIR, reached with no link,
# with that sha256. Files SUMS doesn't list are ignored. SUMS and DIR may be the tenant's, so nothing is followed
# and nothing is read outside DIR.
tree_matches() {
  regular "$1" || return 1
  [ "$(stat -c %s -- "$1" 2>/dev/null)" -le 33554432 ] 2>/dev/null || return 1
  [ -d "$2" ] && [ ! -L "$2" ] || return 1
  php -n -r '
    $root = realpath($argv[2]);
    if ($root === false) exit(1);
    $fh = fopen($argv[1], "r");
    if ($fh === false) exit(1);
    $n = 0;
    while (($line = fgets($fh)) !== false) {
      $line = rtrim($line, "\n");
      if ($line === "") continue;
      if (!preg_match("/^([0-9a-f]{64})  \\.\\/(.+)$/", $line, $m)) exit(1);
      $rel = $m[2];
      if (strpos("/" . $rel . "/", "/../") !== false) exit(1);
      $path = $root . "/" . $rel;
      $walk = $root;
      foreach (explode("/", $rel) as $part) {
        $walk .= "/" . $part;
        if (is_link($walk)) exit(1);
      }
      if (!is_file($path)) exit(1);
      if (hash_file("sha256", $path) !== $m[1]) exit(1);
      $n++;
    }
    exit($n > 0 ? 0 : 1);
  ' -- "$1" "$2" 2>/dev/null
}

case "${1:-}" in
  --id) [ $# -eq 2 ] || usage; vendor_id "$2"; exit ;;
  --sums) [ $# -eq 2 ] || usage; vendor_sums "$2"; exit ;;
esac
[ $# -eq 4 ] || usage
APP="$1"
PKG="$2"
SITE="$3"
STATE="$4"
case "$APP" in gibbon|moodle) ;; *) usage ;; esac

# app_version DIR: the app's version in the code tree DIR (Gibbon's version string, Moodle's integer $version).
app_version() {
  local vf
  case "$APP" in
    gibbon)
      regular "$1/version.php" || return 0
      sed -n "s/^\\\$version[[:space:]]*=[[:space:]]*'\\([0-9][0-9.]*\\)';.*/\\1/p" "$1/version.php" 2>/dev/null | head -n 1
      ;;
    moodle)
      [ ! -L "$1/public" ] || return 0
      for vf in "$1/public/version.php" "$1/version.php"; do
        if regular "$vf"; then
          sed -nE 's/^[[:space:]]*\$version[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$vf" 2>/dev/null | head -n 1
          return 0
        fi
      done
      ;;
  esac
}

# A site on another version is the install's or the upgrade's business: they copy the whole package.
image_version="$(app_version "$PKG")"
[ -n "$image_version" ] && [ "$image_version" = "$(app_version "$SITE")" ] || exit 0

if ! image_id="$(vendor_id "$PKG/vendor")"; then
  log "FAILED: the image's vendor/ has no package list, so the site keeps its own"
  exit 0
fi

# The marker goes in the state folder, which has to be a folder inside the site.
site_real="$(realpath -e -- "$SITE" 2>/dev/null)" || exit 0
state_real="$(realpath -e -- "$STATE" 2>/dev/null)" || state_real=""
if [ -L "$STATE" ] || [ ! -d "$STATE" ] || [ "${state_real#"$site_real"/}" = "$state_real" ]; then
  log "the site's state folder isn't a folder of its own, so vendor/ was left as it is"
  exit 0
fi

V="$SITE/vendor"
NEW="$SITE/vendor.clouve-new"
OLD="$SITE/vendor.clouve-old"
MARKER="$STATE/vendor-id"
SUMS="$STATE/vendor-sums"
UPSTREAM_ID_FILE="$(dirname -- "$PKG")/vendor-upstream.id"
UPSTREAM_SUMS="$(dirname -- "$PKG")/vendor-upstream.sums"

# remove PATH: a link goes as a link, never followed.
remove() { if [ -L "$1" ]; then rm -f -- "$1" 2>/dev/null; elif [ -e "$1" ]; then rm -rf -- "$1" 2>/dev/null; fi; }

copy_composer_files() {
  local f
  for f in composer.json composer.lock; do
    regular "$PKG/$f" || continue
    cp -T --remove-destination -- "$PKG/$f" "$SITE/$f" 2>/dev/null && chown -h www-data:www-data -- "$SITE/$f" 2>/dev/null
  done
}

# put_file DEST: writes stdin to a new file in the state folder and renames it to DEST, so a link at DEST is
# replaced, not followed.
put_file() {
  local tmp
  tmp="$(mktemp -- "$STATE/.vendor.XXXXXX" 2>/dev/null)" || return 1
  if cat > "$tmp" 2>/dev/null && chmod 644 -- "$tmp" 2>/dev/null && mv -fT -- "$tmp" "$1" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null
  return 1
}

# record: the marker says which version's and which libraries Clouve's image put on the site, and the file list
# beside it lets a later image check that tree. The list goes first, so a marker never names a tree without one.
record() {
  vendor_sums "$PKG/vendor" | put_file "$SUMS" && printf '%s %s\n' "$image_version" "$image_id" | put_file "$MARKER"
}

recorded=""
regular "$MARKER" && recorded="$(head -c 256 -- "$MARKER" 2>/dev/null | head -n 1)"

# A temp file put_file left when a start was cut off between mktemp and the rename.
for f in "$STATE"/.vendor.??????; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  rm -f -- "$f" 2>/dev/null
done

# A swap that was cut off between its two renames. vendor.clouve-new is whole then: the old vendor/ moves aside
# only after the copy is done.
if [ ! -e "$V" ] && [ ! -L "$V" ] && [ -d "$NEW" ] && [ ! -L "$NEW" ]; then
  if ! mv -T -- "$NEW" "$V" 2>/dev/null; then
    log "FAILED to finish the swap an earlier start began"
    exit 1
  fi
fi
remove "$NEW"
remove "$OLD"
if [ -e "$NEW" ] || [ -L "$NEW" ] || [ -e "$OLD" ] || [ -L "$OLD" ]; then
  log "FAILED to clear what an earlier start left, so the site keeps its vendor/"
  exit 0
fi

if [ -L "$V" ] || [ ! -d "$V" ]; then
  log "vendor/ on this site isn't a folder, so it was left as it is"
  exit 0
fi

site_id="$(vendor_id "$V")" || site_id=""
if [ -n "$site_id" ] && [ "$site_id" = "$image_id" ]; then
  # Already the image's tree. A start cut off after the swap may not have copied the composer files or written the
  # marker yet.
  if [ "$recorded" != "$image_version $image_id" ]; then
    copy_composer_files
    record
  fi
  exit 0
fi

upstream_id=""
regular "$UPSTREAM_ID_FILE" && upstream_id="$(head -n 1 -- "$UPSTREAM_ID_FILE" 2>/dev/null)"
ours=0
if [ -n "$site_id" ] && [ "$site_id" = "$upstream_id" ] && tree_matches "$UPSTREAM_SUMS" "$V"; then
  ours=1
elif [ -n "$site_id" ] && [ "$recorded" = "$image_version $site_id" ] && tree_matches "$SUMS" "$V"; then
  ours=1
fi
if [ "$ours" != 1 ]; then
  log "vendor/ on this site was changed after Clouve's image put it there, so it was left as it is"
  exit 0
fi

if ! cp -a -- "$PKG/vendor" "$NEW" 2>/dev/null || ! chown -hR www-data:www-data -- "$NEW" 2>/dev/null; then
  remove "$NEW"
  log "FAILED to copy the image's vendor/, so the site keeps its old one"
  exit 0
fi
if ! mv -T -- "$V" "$OLD" 2>/dev/null; then
  remove "$NEW"
  log "FAILED to move the old vendor/ aside, so the site keeps it"
  exit 0
fi
if ! mv -T -- "$NEW" "$V" 2>/dev/null; then
  log "FAILED between the two renames; the next start finishes the swap"
  exit 1
fi
copy_composer_files
remove "$OLD"
record
log "vendor/ now has the image's libraries"
