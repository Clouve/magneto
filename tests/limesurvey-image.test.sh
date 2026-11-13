#!/bin/bash

# ============================================================================
# LimeSurvey image test: what the two images hold
# ============================================================================
# Reads apps/limesurvey/image/Dockerfile and its database Dockerfile, builds
# both images (or takes --image ones) and looks inside them. Nothing here
# needs a database or the network once the images are built.
#
# The LimeSurvey image:
#   - the runtime base, the version, the build number and the checksum are
#     the Dockerfile's, and the build checks the zip against the checksum;
#   - /clouve/limesurvey/package is LimeSurvey 7.10.0 build 261109 with
#     updatable off (the in-app updater would put code on the volume that is
#     newer than the image) and upstream's fix 6487164b in Update_700.php
#     (without it the 6-to-7 database update drops one question's answers);
#   - /var/www/html is empty: the code is copied from the package at the
#     first start, so the base image's own copy is gone;
#   - /clouve and everything in it is root's, the package too, and www-data
#     can create, replace or rename nothing there: root runs the installer,
#     and the AI Assistant reads the persona;
#   - Apache's log, run and lock folders and the log links are root's, so
#     PHP can't point a log at another file before a reload;
#   - the build id is what installer/build-id.sh prints, and a change to one
#     file of the package or of the installer gives another id;
#   - package-stats holds the package's entry count and its size;
#   - the environment names the LimeSurvey version of the package;
#   - Apache denies /clouve/, /node_modules/ and /installer/ over HTTP while
#     it serves the rest (a container runs Apache on a copy of the package),
#     also when a .htaccess in one of those folders grants access, and for
#     other spellings of the path;
#   - the clouve-ops channel: sshd, sudo, the account with no password set,
#     the sshd drop-in, and no SSH host key;
#   - the database client, wget, this checkout's persona and its installer
#     folder;
#   - no password in the image's environment.
# The database image:
#   - MariaDB 11.8 with MARIADB_AUTO_UPGRADE=1, tini as PID 1's command, the
#     clouve-ops account and no SSH host key;
#   - its wrapper refuses a data directory that a newer MariaDB line wrote
#     (MariaDB itself would start on it without complaint), and starts on one
#     from its own line or an older one.
#
# Every container and volume is named ls-img-t-* (LS_TEST_PREFIX changes
# that) and is removed at the end, with the images the test built.
#
# Usage: bash tests/limesurvey-image.test.sh [--image limesurvey=REF] [--image limesurvey-mariadb=REF] [--keep]
# Exit status: 0 when every check passes, 1 when one fails, 2 without Docker.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="${LS_TEST_PREFIX:-ls-img-t-}"
# shellcheck source=lib/limesurvey-test-lib.sh
. "$SCRIPT_DIR/lib/limesurvey-test-lib.sh"

VERSION=7.10.0
BUILD=261109
DB_VERSION=718
SHA256=05b72d1d424a7a6b8ac5ae86f240e14aabe121c3c4e83295d4e64a928786f9db
BASE=martialblog/limesurvey:7.9.1-261102-apache
MARIADB_LINE=11.8

ls_parse_args "$@"
[ "${#LS_ARGS[@]}" -eq 0 ] || { sed -n 's/^# \{0,1\}//; /^Usage:/,/^Exit status/p' "${BASH_SOURCE[0]}" >&2; exit 2; }
ls_need_docker
trap ls_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ls_remove_all

DOCKERFILE="$LS_APP_DIR/image/Dockerfile"
DB_DOCKERFILE="$LS_APP_DIR/image/mariadb/Dockerfile"

echo "The Dockerfiles"
assert_eq "the runtime base is $BASE" "1" "$(grep -cE "^FROM $BASE( |\$)" "$DOCKERFILE")"
assert_eq "no other image is named in a FROM" "0" "$(grep -E '^FROM ' "$DOCKERFILE" | grep -cvE "^FROM ($BASE|[a-z]+)( |\$)")"
assert_eq "ARG LIMESURVEY_VERSION=$VERSION" "1" "$(grep -cx "ARG LIMESURVEY_VERSION=$VERSION" "$DOCKERFILE")"
assert_eq "ARG LIMESURVEY_BUILD=$BUILD" "1" "$(grep -cx "ARG LIMESURVEY_BUILD=$BUILD" "$DOCKERFILE")"
assert_eq "ARG LIMESURVEY_SHA256 is the published checksum" "1" "$(grep -cx "ARG LIMESURVEY_SHA256=$SHA256" "$DOCKERFILE")"
assert_eq "the build checks the zip against it (sha256sum -c)" "1" \
  "$(grep -c 'LIMESURVEY_SHA256}.*sha256sum -c' "$DOCKERFILE")"
assert_eq "the zip comes from upstream's download server" "1" \
  "$(grep -c 'https://download.limesurvey.org/latest-master/limesurvey${LIMESURVEY_VERSION}+${LIMESURVEY_BUILD}.zip' "$DOCKERFILE")"
assert_eq "upstream's fix is kept in the image folder" "1" \
  "$(grep -c '^commit 6487164b4b1771df3de3f1934a0dbde5d983419a' "$LS_APP_DIR/image/Update_700-fix-6487164b.patch" 2>/dev/null)"
assert_eq "the database base is mariadb:$MARIADB_LINE" "1" "$(grep -cx "FROM mariadb:$MARIADB_LINE" "$DB_DOCKERFILE")"
PERSONA="$LS_APP_DIR/image/context/limesurvey/CONTEXT.md.tpl"
# shellcheck disable=SC2016  # the persona's own variable names, for grep
assert_eq "the image folder has the persona, which names both hosts" "2" \
  "$(grep -c -e '^- `${LIMESURVEY_HOST}`' -e '^- `${LIMESURVEY_DB_HOST}`' "$PERSONA" 2>/dev/null)"

echo
echo "The LimeSurvey image"
if ! ls_image limesurvey; then
  fail "the image builds"
  echo; printf '%sLimeSurvey image checks failed.%s\n' "$RED" "$RESET"; exit 1
fi
IMAGE="${LS_IMAGE[limesurvey]}"
pass "the image is here ($IMAGE)"
# run CMD...: a command in a throwaway container of the image, as root, with no network.
run() { docker run --rm --network none --user root --entrypoint "$1" "$IMAGE" "${@:2}" 2>&1; }
# as_www CMD...: the same as www-data, the user that LimeSurvey's PHP runs as.
as_www() { docker run --rm --network none --user www-data --entrypoint "$1" "$IMAGE" "${@:2}" 2>&1; }

# shellcheck disable=SC2016  # PHP code
got="$(run php -r '$c = include "/clouve/limesurvey/package/application/config/version.php";
  echo $c["versionnumber"], " ", $c["dbversionnumber"], " ", $c["buildnumber"], " ", var_export($c["updatable"], true);')"
assert_eq "the package is LimeSurvey $VERSION build $BUILD, updatable off" "$VERSION $DB_VERSION $BUILD false" "$got"
assert_eq "Update_700.php has upstream's fix 6487164b" "1" "$(run grep -c \
  'function compactLegacyRankingValues(string $tableName, array $columnNames, array $fieldMap): void' \
  /clouve/limesurvey/package/application/helpers/update/updates/Update_700.php)"
assert_eq "and calls it with the field map" "1" "$(run grep -c \
  'compactLegacyRankingValues($TABLE_NAME, $allColumnNames, $fields);' \
  /clouve/limesurvey/package/application/helpers/update/updates/Update_700.php)"
assert_eq "the package's files are root's" "root:root" \
  "$(run stat -c '%U:%G' /clouve/limesurvey/package/application/config/version.php)"
assert_eq "and www-data, who copies them to the volume, can read every one" "0" \
  "$(as_www sh -c 'find /clouve/limesurvey/package /clouve/limesurvey/installer ! -readable | wc -l')"
assert_eq "the SuiteCRM plugin is in the package" "1" \
  "$(run sh -c 'ls /clouve/limesurvey/package/plugins/SuiteCRMIntegration/config.xml | wc -l')"
assert_eq "/var/www/html is empty and www-data's (the base image's copy is gone)" "0 www-data:www-data" \
  "$(run sh -c 'echo "$(ls -A /var/www/html | wc -l) $(stat -c %U:%G /var/www/html)"')"
assert_eq "the image's build id names the version and the build" "1" \
  "$(run sh -c "grep -cE '^$VERSION\\+$BUILD-[0-9a-f]{12}\$' /clouve/limesurvey/image-build")"
# The id's hash covers every file of the installer and of the package. A rebuilt image with a fix to LimeSurvey's
# own code then has another id, and only an image with another id tries a failed upgrade again. One throwaway
# container prints the id five times: as the image is, once more, with one more byte in a package file, with a
# package file renamed, and with an installer file changed.
build_id="$(run cat /clouve/limesurvey/image-build)"
# shellcheck disable=SC2016  # the script is for the bash in the container
ids="$(run bash -c '
  id() { /clouve/limesurvey/installer/build-id.sh 2>&1 | head -n 1; }
  p=/clouve/limesurvey/package
  echo "start $(id)"
  echo "again $(id)"
  printf " " >> "$p/application/helpers/update/updates/Update_700.php"
  echo "byte $(id)"
  mv "$p/docs/release_notes.txt" "$p/docs/release_notes_moved.txt"
  echo "name $(id)"
  echo "# changed" >> /clouve/limesurvey/installer/lib.sh
  echo "installer $(id)"')"
id_of() { sed -n "s/^$1 //p" <<< "$ids"; }
# another_id LABEL ID BEFORE: ID is a build id of this version and differs from BEFORE.
another_id() {
  if [[ "$2" =~ ^$VERSION\+$BUILD-[0-9a-f]{12}$ && "$2" != "$3" ]]; then pass "$1"; else
    fail "$1"; printf '       before: %q\n       after:  %q\n' "$3" "$2"; fi
}
assert_eq "installer/build-id.sh prints the image's build id" "$build_id" "$(id_of start)"
assert_eq "and the same id when it runs again" "$build_id" "$(id_of again)"
another_id "one more byte in a package file (Update_700.php) gives another id" "$(id_of byte)" "$(id_of start)"
another_id "a renamed package file gives another id" "$(id_of name)" "$(id_of byte)"
another_id "a changed installer file gives another id" "$(id_of installer)" "$(id_of name)"
# The upgrade reads package-stats to check the volume's free inodes and space before it copies the package.
assert_eq "package-stats is root's, mode 644, two lines" "root:root 644 2" \
  "$(run sh -c 'f=/clouve/limesurvey/package-stats; echo "$(stat -c "%U:%G %a" "$f") $(wc -l < "$f")"')"
assert_eq "it holds the package's entry count (find) and its size (du -sk)" \
  "$(run sh -c 'p=/clouve/limesurvey/package; printf "entries=%s\nkb=%s\n" "$(find "$p" | wc -l)" "$(du -sk "$p" | cut -f1)"')" \
  "$(run cat /clouve/limesurvey/package-stats)"

tools="$(run sh -c 'for t in mariadb mariadb-dump wget curl sshd sudo ssh-keygen runuser gzip sha256sum; do
  command -v "$t" >/dev/null 2>&1 || command -v "/usr/sbin/$t" >/dev/null 2>&1 || echo "missing $t"; done')"
assert_eq "the database client, wget, sshd and sudo are installed" "" "$tools"
listing="$(run sh -c 'ls -A /etc/ssh')"
if ! grep -qx sshd_config <<< "$listing"; then
  fail "the image holds no SSH host key (its /etc/ssh couldn't be listed)"
else
  assert_eq "the image holds no SSH host key" "" "$(grep '^ssh_host_' <<< "$listing")"
fi
assert_eq "the sshd drop-in lets only clouve-ops in" "AllowUsers clouve-ops" \
  "$(run grep -x 'AllowUsers clouve-ops' /etc/ssh/sshd_config.d/clouve-ops.conf)"
assert_eq "clouve-ops has passwordless sudo" "clouve-ops ALL=(ALL) NOPASSWD: ALL" "$(run cat /etc/sudoers.d/clouve-ops)"
shadow="$(run sh -c "grep '^clouve-ops:' /etc/shadow | cut -d: -f2")"
case "$shadow" in
  '!'* | '*'*) pass "clouve-ops has no password in the image" ;;
  *) fail "clouve-ops has no password in the image" ;;
esac
assert_eq "the persona at /clouve/context/limesurvey/CONTEXT.md.tpl is this checkout's" \
  "$(sha256sum < "$PERSONA" | cut -d' ' -f1)" "$(run sh -c 'sha256sum < /clouve/context/limesurvey/CONTEXT.md.tpl | cut -d" " -f1')"
# Both sides sort in the C locale: the host's locale and the image's would order some names differently.
in_image="$(run sh -c 'cd /clouve/limesurvey/installer && find . -type f | LC_ALL=C sort | xargs sha256sum')"
in_tree="$(cd "$LS_APP_DIR/image/installer" && find . -type f | LC_ALL=C sort | xargs sha256sum)"
if [[ -n "$in_tree" && "$in_image" == "$in_tree" ]]; then
  pass "the image's installer folder is this checkout's"
else
  fail "the image's installer folder is this checkout's"
  diff <(printf '%s\n' "$in_tree") <(printf '%s\n' "$in_image") | sed 's/^/       /' | head -n 10
fi
image_env="$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE")"
# The base image's own value names the LimeSurvey it shipped, which is not the one in the package.
assert_eq "the environment names the LimeSurvey version of the package" "LIMESURVEY_VERSION=$VERSION+$BUILD" \
  "$(grep '^LIMESURVEY_VERSION=' <<< "$image_env")"
env_names="$(cut -d= -f1 <<< "$image_env")"
assert_eq "no variable of the image names a password, a secret, a token or a key" "" \
  "$(grep -iE 'PASS|SECRET|TOKEN|_KEY$' <<< "$env_names")"
assert_eq "the entrypoint is the image's own" '[/clouve/limesurvey/installer/entrypoint.sh] [apache2-foreground]' \
  "$(docker image inspect --format '{{.Config.Entrypoint}} {{.Config.Cmd}}' "$IMAGE")"
assert_eq "Apache's configuration is root's, so PHP can't change it" "root:root root:root" \
  "$(run sh -c 'echo "$(stat -c %U:%G /etc/apache2) $(stat -c %U:%G /etc/apache2/conf-enabled/zz-clouve.conf)"')"

echo
echo "What www-data can't change"
# Root runs the installer and reads image-build, and the AI Assistant reads the persona, so PHP code (www-data) must
# not be able to change any of it. The package is root's too: the entrypoint only reads it.
assert_eq "/clouve and /clouve/limesurvey are root's, mode 755" "root:root 755, root:root 755" \
  "$(run sh -c 'echo "$(stat -c "%U:%G %a" /clouve), $(stat -c "%U:%G %a" /clouve/limesurvey)"')"
for entry in context limesurvey/installer limesurvey/package limesurvey/standin limesurvey/image-build \
  limesurvey/package-stats; do
  assert_eq "/clouve/$entry is root's" "root:root" "$(run stat -c '%U:%G' "/clouve/$entry")"
done
assert_eq "nothing under /clouve has another owner or group, or is writable by all" "" \
  "$(run sh -c 'find /clouve \( ! -user root -o ! -group root -o \( -perm -0002 ! -type l \) \) | head -n 5')"
assert_eq "www-data finds nothing under /clouve that it may write" "" \
  "$(as_www sh -c 'find /clouve -writable ! -type l | head -n 5')"
# Each line this prints is something www-data managed to do. Renaming a folder of the image fails on some storage
# drivers for a reason of their own (overlayfs without redirect_dir), so the owners are checked above as well.
# shellcheck disable=SC2016  # the script is for the bash in the container
did="$(as_www bash -c '
  cd /clouve/limesurvey || exit 1
  for d in /clouve /clouve/context /clouve/context/limesurvey . installer package package/application/config standin; do
    touch "$d/www-probe" 2>/dev/null && echo "made $d/www-probe"
  done
  for f in image-build package-stats installer/entrypoint.sh installer/build-id.sh package/index.php \
    /clouve/context/limesurvey/CONTEXT.md.tpl; do
    [ -e "$f" ] || { echo "$f is missing"; continue; }
    { echo changed >> "$f"; } 2>/dev/null && echo "wrote to $f"
    mv "$f" "$f.www" 2>/dev/null && { echo "renamed $f"; continue; }
    rm -f "$f" 2>/dev/null
    [ -e "$f" ] || echo "removed $f"
  done
  for d in /clouve/context installer package standin /clouve/limesurvey; do
    mv "$d" "$d.www" 2>/dev/null && echo "renamed $d"
  done')"
assert_eq "www-data can create, replace or rename nothing under /clouve" "" "$did"

# Apache's parent process is root. It opens the logs and writes its PID file at a start and at each graceful reload,
# so a log link or a folder that www-data could change would let PHP code write a file as root.
assert_eq "Apache's log, run and lock folders are root's, mode 755" "root:root 755, root:root 755, root:root 755" \
  "$(run sh -c 'for d in /var/log/apache2 /var/run/apache2 /var/lock/apache2; do stat -c "%U:%G %a" "$d"; done |
    paste -s -d, | sed "s/,/, /g"')"
assert_eq "and so is everything in them, the log links too" "" \
  "$(run sh -c 'find /var/log/apache2 /var/run/apache2 /var/lock/apache2 \
    \( ! -user root -o ! -group root -o \( -perm -0002 ! -type l \) \) | head -n 5')"
assert_eq "the log links point at the container's output" "/dev/stdout /dev/stderr /dev/stdout" \
  "$(run sh -c 'cd /var/log/apache2 && echo "$(readlink access.log) $(readlink error.log) $(readlink other_vhosts_access.log)"')"
# shellcheck disable=SC2016  # the script is for the bash in the container
did="$(as_www bash -c '
  for d in /var/log/apache2 /var/run/apache2 /var/lock/apache2; do
    touch "$d/www-probe" 2>/dev/null && echo "made $d/www-probe"
  done
  cd /var/log/apache2 || exit 1
  for l in access.log error.log other_vhosts_access.log; do
    mv "$l" "$l.www" 2>/dev/null && { echo "renamed $l"; continue; }
    rm -f "$l" 2>/dev/null
    [ -L "$l" ] || echo "removed $l"
  done')"
assert_eq "www-data can create nothing in them and can't move or remove a log link" "" "$did"

echo
echo "What Apache serves"
WEB="${PREFIX}web"
# Apache on a copy of the package, with a file in each folder the drop-in denies. No database: static files only.
# shellcheck disable=SC2016  # the script is for the bash in the container
docker run -d --name "$WEB" --network none --user root --entrypoint bash "$IMAGE" -c '
  cp -a /clouve/limesurvey/package/. /var/www/html/ &&
  mkdir -p /var/www/html/clouve/upgrade-6.16.1-to-7.10.0 /var/www/html/node_modules/probe /var/www/html/installer &&
  echo dump > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/db.sql.gz &&
  echo state > /var/www/html/clouve/install-in-progress &&
  echo js > /var/www/html/node_modules/probe/index.js &&
  echo served > /var/www/html/upload/probe.txt &&
  sed -i "s/Listen 80\$/Listen 8080/" /etc/apache2/ports.conf /etc/apache2/sites-available/000-default.conf &&
  exec apache2-foreground' >/dev/null
for _ in $(seq 1 60); do [ "$(ls_http "$WEB" /upload/probe.txt)" = 200 ] && break; sleep 1; done
assert_eq "a file in upload/ is served (Apache works)" "200" "$(ls_http "$WEB" /upload/probe.txt)"
assert_eq "the upgrade's database dump is denied" "403" "$(ls_http "$WEB" /clouve/upgrade-6.16.1-to-7.10.0/db.sql.gz)"
assert_eq "a state file in clouve/ is denied" "403" "$(ls_http "$WEB" /clouve/install-in-progress)"
assert_eq "the clouve/ folder itself is denied" "403" "$(ls_http "$WEB" /clouve/)"
assert_eq "a file in node_modules/ is denied" "403" "$(ls_http "$WEB" /node_modules/probe/index.js)"
installer_file="$(docker exec "$WEB" sh -c 'cd /var/www/html && find installer -type f | head -n 1')"
assert_eq "a file in installer/ is denied ($installer_file)" "403" "$(ls_http "$WEB" "/$installer_file")"
assert_eq "the installer/ folder itself is denied" "403" "$(ls_http "$WEB" /installer/)"
# other_spellings NOTE: six other spellings of each of the three paths. curl sends each one as written. (Upper case
# is not among them: it names another folder, and tests/limesurvey-apache.test.sh asks a running site for it.)
other_spellings() {
  local denied first rest open spelling code
  for denied in clouve/install-in-progress node_modules/probe/index.js "$installer_file"; do
    first="${denied%%/*}"
    rest="${denied#*/}"
    open=""
    for spelling in "//$denied" "/./$denied" "/upload/../$denied" "/$first//$rest" "/$first/./$rest" \
      "/%$(printf '%02x' "'${first:0:1}")${first:1}/$rest"; do
      code="$(ls_http "$WEB" "$spelling" --path-as-is)"
      case "$code" in 403 | 404) ;; *) open="$open $spelling=$code" ;; esac
    done
    assert_eq "six other spellings of /$denied answer 403 or 404$1" "" "$open"
  done
}
other_spellings ""
# A .htaccess that grants access, written into each denied folder and into a folder below it. Everything in this
# container is root's and readable by all, so a 403 here is Apache's rule and not a file's mode.
assert_eq "Apache's user can read the dump's file, so the 403 above is the rule's" "dump" \
  "$(docker exec -u www-data "$WEB" cat /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/db.sql.gz 2>&1)"
# shellcheck disable=SC2016  # the script is for the bash in the container
docker exec -u root "$WEB" bash -c '
  for d in clouve clouve/upgrade-6.16.1-to-7.10.0 node_modules node_modules/probe installer; do
    printf "%s\n" "<FilesMatch \".*\">" "    Require all granted" "</FilesMatch>" > "/var/www/html/$d/.htaccess" &&
      chmod 644 "/var/www/html/$d/.htaccess" || echo "could not write $d/.htaccess"
  done'
assert_eq "with a .htaccess in clouve/ that grants access, the dump is still denied" "403" \
  "$(ls_http "$WEB" /clouve/upgrade-6.16.1-to-7.10.0/db.sql.gz)"
assert_eq "and so is a state file" "403" "$(ls_http "$WEB" /clouve/install-in-progress)"
assert_eq "with one in node_modules/, a file there is still denied" "403" "$(ls_http "$WEB" /node_modules/probe/index.js)"
assert_eq "with one in installer/, a file there is still denied" "403" "$(ls_http "$WEB" "/$installer_file")"
assert_eq "the rest is still served" "200" "$(ls_http "$WEB" /upload/probe.txt)"
other_spellings ", with the .htaccess files too"
docker rm -f -v "$WEB" >/dev/null 2>&1

echo
echo "The database image"
if ! ls_image limesurvey-mariadb; then
  fail "the image builds"
  echo; printf '%sLimeSurvey image checks failed.%s\n' "$RED" "$RESET"; exit 1
fi
DB_IMAGE="${LS_IMAGE[limesurvey-mariadb]}"
pass "the image is here ($DB_IMAGE)"
dbrun() { docker run --rm --network none --user root --entrypoint "$1" "$DB_IMAGE" "${@:2}" 2>&1; }
assert_contains "it is MariaDB $MARIADB_LINE" "$(dbrun mariadbd --version)" " $MARIADB_LINE."
assert_eq "tini starts the wrapper" '[/usr/bin/tini -- /usr/local/bin/clouve-entrypoint.sh] [mariadbd]' \
  "$(docker image inspect --format '{{.Config.Entrypoint}} {{.Config.Cmd}}' "$DB_IMAGE")"
db_env="$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$DB_IMAGE")"
assert_eq "MARIADB_AUTO_UPGRADE is 1" "1" "$(grep -cx 'MARIADB_AUTO_UPGRADE=1' <<< "$db_env")"
assert_eq "no variable of the image names a password" "" "$(cut -d= -f1 <<< "$db_env" | grep -iE 'PASS|SECRET|TOKEN')"
db_listing="$(dbrun sh -c 'ls -A /etc/ssh')"
if ! grep -qx sshd_config <<< "$db_listing"; then
  fail "the image holds no SSH host key (its /etc/ssh couldn't be listed)"
else
  assert_eq "the image holds no SSH host key" "" "$(grep '^ssh_host_' <<< "$db_listing")"
fi
db_shadow="$(dbrun sh -c "grep '^clouve-ops:' /etc/shadow | cut -d: -f2")"
case "$db_shadow" in
  '!'* | '*'*) pass "clouve-ops has no password in the image" ;;
  *) fail "clouve-ops has no password in the image" ;;
esac

# start_on_data NAME INFO: a database container on a data directory whose mariadb_upgrade_info holds INFO.
start_on_data() {
  docker volume create "${PREFIX}$1" >/dev/null
  docker run --rm --network none --user root -v "${PREFIX}$1:/var/lib/mysql" --entrypoint sh "$DB_IMAGE" -c \
    "printf '%s\n' '$2' > /var/lib/mysql/mariadb_upgrade_info && chown -R mysql:mysql /var/lib/mysql" >/dev/null 2>&1
  docker run -d --name "${PREFIX}$1" --network none --memory "$LS_MEMORY" -v "${PREFIX}$1:/var/lib/mysql" \
    -e MYSQL_DATABASE=limesurvey -e MYSQL_USER=limesurvey -e "MYSQL_PASSWORD=$LS_DB_PW" \
    -e "MYSQL_ROOT_PASSWORD=$LS_DB_ROOT_PW" "$DB_IMAGE" >/dev/null
}
start_on_data newer "12.3.2-MariaDB"
code="$(ls_wait_exit "${PREFIX}newer" 60)"
log="$(docker logs "${PREFIX}newer" 2>&1)"
assert_eq "a data directory from MariaDB 12.3 stops the container" "1" "$code"
assert_contains "the log says which line wrote it and which the image is" "$log" \
  "was written by MariaDB 12.3, which is newer than this image's MariaDB $MARIADB_LINE"
assert_lacks "mariadbd never started on it" "$log" "ready for connections"
assert_eq "the log holds no password" "0" "$(ls_secrets_in "$log")"
info_after="$(docker run --rm --network none --user root -v "${PREFIX}newer:/var/lib/mysql" --entrypoint cat "$DB_IMAGE" \
  /var/lib/mysql/mariadb_upgrade_info 2>&1)"
assert_eq "and the data directory is as it was" "12.3.2-MariaDB" "$info_after"
# A data directory with nothing but an older line's marker: the wrapper lets it through, and the official entrypoint
# initializes the empty directory as usual.
start_on_data older "10.11.6-MariaDB"
if ls_wait_log "${PREFIX}older" "ready for connections" 120; then
  pass "a data directory from an older line (10.11) starts"
else
  fail "a data directory from an older line (10.11) starts"
  docker logs --tail 10 "${PREFIX}older" 2>&1 | sed 's/^/       | /'
fi
docker rm -f -v "${PREFIX}newer" "${PREFIX}older" >/dev/null 2>&1

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sLimeSurvey image checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sLimeSurvey image checks failed.%s\n' "$RED" "$RESET"
exit 1
