#!/bin/bash

# ============================================================================
# SuiteCRM image test: what the two images hold
# ============================================================================
# Reads apps/suitecrm/image/Dockerfile and apps/suitecrm/image/mariadb/Dockerfile,
# builds both images and looks inside them. No SuiteCRM is installed here
# (tests/suitecrm-entrypoint.test.sh and tests/suitecrm-upgrade.test.sh do that).
#
# The SuiteCRM image:
#   - the Dockerfile builds on php:8.3-apache alone (no Composer stage), names
#     SuiteCRM's version and the zip's SHA-256 as ARGs, checks the zip against
#     the checksum, pins the PHP extension installer to a release with its own
#     checksum, and removes the SSH host keys in the RUN that installs
#     openssh-server;
#   - nothing in the build is fetched over plain HTTP, and the three Debian
#     packages the imap extension needs are pinned to a SHA-256 each, for amd64
#     and for arm64;
#   - the package at /clouve/suitecrm/app is SuiteCRM 8.10.2, and the release
#     zip is kept next to it with the checksum the Dockerfile names;
#   - /clouve and everything under it is root's and closed to writing by
#     anyone else, so www-data can change nothing that root runs or reads;
#   - Apache's log, run and lock folders are root's, and the volume's mount
#     point is not open to everyone;
#   - no compiler or build tool is left, and every PHP extension still loads;
#   - the build id follows the installer, the Dockerfile, the package, PHP's
#     settings and Apache's configuration;
#   - the package's keep-list carries the image's own entries (clouve,
#     .suitecrm_initialized, .suitecrm_url), so SuiteCRM's upgrade leaves them;
#   - PHP is 8.3 with imap and every extension SuiteCRM asks for, and neither
#     Composer nor git is in the image;
#   - Apache's configuration is valid, serves /var/www/html/public, turns HTTPS
#     on for a forwarded HTTPS request, takes the client's address from the
#     ingress's header for private peers only, logs a request without its
#     query string and without the Referer, and gives no folder listing;
#   - the clouve-ops account, its sudo rule and the sshd drop-in are there, the
#     account has no password, and no layer holds an SSH host key;
#   - no layer was made with a password and the image's environment names none;
#   - this checkout's persona is at /clouve/context/suitecrm/CONTEXT.md.tpl;
#   - the installer in the image is this checkout's, and a build id is recorded;
#   - the PHP libraries with published advisories are at their fixed releases, in
#     the package and in the kept zip, and the zip holds the package's files;
#   - root reads and writes the state folder only from inside it, deletes and
#     changes owners in the install only from inside the folder it checked, and
#     loads a dump only as www-data with the client's --sandbox (the scripts,
#     and sc_in_state and sc_in_dir run against a swap and a link);
#   - Apache and PHP name no version, PHP's sessions run in strict mode, the
#     clouve-ops sshd forwards nothing and logs to the container's log, and only
#     sudo and unix_chkpwd keep a set-user-ID or set-group-ID bit.
#
# The database image:
#   - the Dockerfile builds on mariadb:12.3 and sets MARIADB_AUTO_UPGRADE=1;
#   - tini is PID 1's program, gosu is the rebuilt one and the environment
#     names its real version, no layer holds an SSH host key, the sshd drop-in
#     is root's alone to write, and the clouve-ops account has no password;
#   - the base's packages are upgraded, its sshd forwards nothing and logs to
#     the container's log, only sudo and unix_chkpwd keep a set-ID bit, and a
#     new data directory gets root for localhost only;
#   - on a new disk the server starts and records its version; a data directory
#     that a newer MariaDB line wrote (13.0) is refused with a clear message and
#     the server is never started; one from an older line (12.1) starts, and the
#     automatic upgrade records the new version.
#
# --image NAME=REF uses an image that is already built (NAME is suitecrm or
# suitecrm-mariadb); otherwise the test builds it and removes it at the end.
# Every container and volume is named sc-t-img-* (SUITECRM_TEST_PREFIX changes
# the sc-t- part). Needs Docker and python3. No network is used after the build.
#
# Usage: bash tests/suitecrm-image.test.sh [--image NAME=REF]...
# Exit status: 0 when every check passes, 1 when one fails, 2 without Docker.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/suitecrm-test-lib.sh
. "$SCRIPT_DIR/lib/suitecrm-test-lib.sh"
SC_PREFIX="${SC_PREFIX}img-"
IMAGE_DIR="$SC_REPO/apps/suitecrm/image"
VERSION=8.10.2
SHA256=ac4693d10ea2d6cd20b3256098781d134599d88878fb24e8dc127038d624f5a8

while [ $# -gt 0 ]; do
  case "$1" in
    --image) sc_parse_image_option "${2:-}" || { echo "Usage: bash tests/suitecrm-image.test.sh [--image NAME=REF]..." >&2; exit 2; }; shift ;;
    *) echo "Usage: bash tests/suitecrm-image.test.sh [--image NAME=REF]..." >&2; exit 2 ;;
  esac
  shift
done
sc_need_docker
trap sc_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sc_remove_resources    # leftovers of a run that was killed

# --- the Dockerfiles ------------------------------------------------------------
echo "The SuiteCRM Dockerfile"
dockerfile="$IMAGE_DIR/Dockerfile"
# The Dockerfile's instructions as logical lines: comments dropped, a line ending in \ joined with the next.
logical() { sed -e '/^[[:space:]]*#/d' "$1" | sed -e ':a' -e '/\\$/N; s/\\\n/ /; ta'; }
lines="$(logical "$dockerfile" 2>/dev/null)"
assert_eq "it builds on php:8.3-apache and on nothing else" "FROM php:8.3-apache" "$(grep -i '^FROM ' <<< "$lines")"
assert_eq "SuiteCRM's version is an ARG" "ARG SUITECRM_VERSION=$VERSION" "$(grep '^ARG SUITECRM_VERSION=' <<< "$lines")"
assert_eq "the zip's SHA-256 is an ARG" "ARG SUITECRM_SHA256=$SHA256" "$(grep '^ARG SUITECRM_SHA256=' <<< "$lines")"
# shellcheck disable=SC2016  # the text is the Dockerfile's
assert_eq "the build checks the zip against that checksum" "1" \
  "$(grep -c 'echo "${SUITECRM_SHA256}  .*\.zip" | sha256sum -c -' <<< "$lines")"
assert_eq "no Composer and no git in the build" "0" "$(grep -ciE 'composer|(^|[[:space:]])git([[:space:]]|$)' <<< "$lines")"
assert_eq "the extension installer is pinned to a release, with its checksum" "1" \
  "$(grep -cE '^ADD --checksum=sha256:[0-9a-f]{64} .*docker-php-extension-installer/releases/download/[0-9]+\.[0-9]+\.[0-9]+/install-php-extensions ' <<< "$lines")"
assert_eq "nothing is fetched from a moving 'latest'" "0" "$(grep -c 'releases/latest' <<< "$lines")"
assert_eq "the RUN that installs openssh-server removes the SSH host keys" "1" \
  "$(grep -c '^RUN .*openssh-server.*rm -f /etc/ssh/ssh_host_\*' <<< "$lines")"
assert_eq "the persona folder is copied in" "1" "$(grep -c '^COPY context/ /clouve/context/$' <<< "$lines")"
# The imap extension needs Debian 12's c-client packages. The extension installer would fetch them over plain HTTP
# and install them unchecked, so the Dockerfile fetches them itself, over HTTPS, and checks each one.
assert_eq "nothing in the build is fetched over plain HTTP" "0" "$(grep -c 'http://' <<< "$lines")"
assert_eq "the c-client packages come over HTTPS from Debian" "1" \
  "$(grep -c 'https://deb.debian.org/debian/pool/main/u/uw-imap/' <<< "$lines")"
flat="$(tr -s ' \t' ' ' <<< "$lines")"
for arch in amd64 arm64; do
  # One architecture's branch of the case: three names, each with 64 hex digits.
  pinned="$(grep -o "$arch) [^)]*;;" <<< "$flat" | grep -oE '(s_mlock|s_lib|s_dev)=[0-9a-f]{64}' | cut -d= -f1 | sort | xargs)"
  assert_eq "the three packages are pinned to a SHA-256 each for $arch" "s_dev s_lib s_mlock" "$pinned"
done
assert_eq "each one is checked before it is installed" "1" "$(grep -c 'sha256sum -c -; done' <<< "$flat")"
# The extension installer fetches nothing when it finds the three packages, so they have to be there before it runs.
if [ "$(grep -n 'pool/main/u/uw-imap/' <<< "$lines" | head -n 1 | cut -d: -f1)" -lt \
     "$(grep -n '^RUN install-php-extensions' <<< "$lines" | head -n 1 | cut -d: -f1)" ] 2>/dev/null; then
  pass "and they are installed before the extension installer runs"
else
  fail "and they are installed before the extension installer runs"
fi

echo
echo "The database Dockerfile"
db_lines="$(logical "$IMAGE_DIR/mariadb/Dockerfile" 2>/dev/null)"
assert_eq "it builds on mariadb:12.3" "FROM mariadb:12.3" "$(grep -i '^FROM ' <<< "$db_lines" | grep -v ' AS gosu$')"
assert_eq "it sets MARIADB_AUTO_UPGRADE=1" "1" "$(grep -c '^ENV MARIADB_AUTO_UPGRADE=1$' <<< "$db_lines")"
assert_eq "the RUN that installs openssh-server removes the SSH host keys" "1" \
  "$(grep -c '^RUN .*openssh-server.*rm -f /etc/ssh/ssh_host_\*' <<< "$db_lines")"
# The base's own packages go to their newest versions in the same Ubuntu release, as the app image's do. MariaDB's
# packages come from a list pinned to one release, so the server doesn't move.
assert_eq "the RUN that installs openssh-server first upgrades the base's packages" "1" \
  "$(grep -c '^RUN apt-get update && apt-get -y upgrade && apt-get install .*openssh-server' <<< "$db_lines")"

# --- what root does in folders www-data can change --------------------------------
# www-data owns the install and tmp/, so it can rename the state folder tmp/clouve-backup, or public/, and put
# its own folder or a link in its place between root's check and root's use. So root reads and writes the state
# folder only from inside it (sc_in_state), deletes and changes owners in the install only from inside the folder
# it checked (sc_in_dir), and loads a dump with the client's sandbox on, as www-data.
echo
echo "What root does in folders www-data can change (the installer's scripts)"
scripts="$(for f in lib.sh upgrade.sh entrypoint.sh loops.sh release-scheduler.sh; do logical "$IMAGE_DIR/installer/$f"; done)"
NL=$'\n'
upgrade_lines="$(logical "$IMAGE_DIR/installer/upgrade.sh")"
# A client that reads SQL from its standard input runs the client commands in it (system, source, tee) as its own
# user. The sandbox refuses them.
assert_eq "every database client in upgrade.sh that reads its standard input has --sandbox" "0" \
  "$(grep -E '(^|[[:space:]])mysql --defaults-extra-file' <<< "$upgrade_lines" | grep -vE '(^|[[:space:]])-e[[:space:]]' | grep -vc -- '--sandbox')"
assert_eq "the dump is loaded by a client that runs as www-data" "1 0" \
  "$(grep 'db\.sql\.gz' <<< "$upgrade_lines" | grep -c 'sc_as_www mysql --defaults-extra-file="\$SC_WWW_CNF" --sandbox') $(grep 'db\.sql\.gz' <<< "$upgrade_lines" | grep -E '(^|[[:space:]])mysql ' | grep -vc sc_as_www)"
go_back="$(awk '/^### Go back by hand/ { found = 1 } found && /^```bash/ { inside = 1; next } inside && /^```/ { exit } inside' \
  "$SC_REPO/apps/suitecrm/README.md")"
assert_eq "the README's way back by hand loads the dump with --sandbox" "1" \
  "$(grep -c '^ *gzip -dc "\$S/\$B/db.sql.gz" | mysql --defaults-extra-file=[^ ]* --sandbox ' <<< "$go_back")"
# Its removals and changes of owner run inside folders it checked, and nothing is dropped or removed unless the
# checks, the dump's among them, said ok.
assert_eq "and it removes and changes owners only inside folders it checked, after checks that include the dump" "0 0 1 1" \
  "$(grep -cE '^ *(find|chown|rm) [^ ]* *(public|cache|tmp)' <<< "$go_back") $(grep -cE '^ *chown -h www-data:www-data \. public' <<< "$go_back") $(grep -c "grep -qF '/\*M!999999" <<< "$go_back") $(grep -c '^echo "\${ok:-stop' <<< "$go_back")"
# No command names a file of the state folder by its path: the folder could be another one by then.
# The commands that read or write a file: a file of the state folder by its path, or the folder's contents by a glob.
state_by_path='(^|[;&|(]|then |do |else )[[:space:]]*(rm|mv|cp|chmod|chown|mkdir|tee|tar|gzip|sha256sum|sed|grep|cat|sync)[[:space:]].*"\$(SC_STATE_DIR"?/|SC_STATE["./]|SC_ASIDE|SC_SKIPPED|SC_ATTENTION|SC_SCHEDULER_HELD|SC_RESTORE_MARKER|SC_LOOPS_PAUSED|console_log|backup["/.]|partial)'
state_redirect='[<>][[:space:]]*"\$(SC_STATE_DIR"?/|SC_STATE["./]|SC_ASIDE|SC_SKIPPED|SC_ATTENTION|console_log|backup["/.]|partial)'
assert_eq "no command reads or writes a file of the state folder by its path" "" \
  "$(grep -nE "$state_by_path|$state_redirect" <<< "$scripts" | cut -c1-120)"
# www-data can move tmp/, with root's state folder in it, into any folder of its own. So root deletes nothing in the
# install: every find that deletes runs as www-data (sc_clear), which can't remove root's state folder. The one in
# sc_symfony_cache_drop runs in a shell of www-data's too.
lib_lines="$(logical "$IMAGE_DIR/installer/lib.sh")"
assert_eq "every find that deletes in the install runs as www-data, from the folder it checked" "0" \
  "$(grep -E -- '-exec rm' <<< "$lib_lines$NL$upgrade_lines" | grep -v 'sc_in_dir "\$dir" sc_as_www find \. ' |
    grep -vc '^ *find cache -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2> /dev/null$')"
assert_eq "and upgrade.sh removes nothing in the install as root" "0" \
  "$(grep -vE '^[[:space:]]*(up_skip|up_failed|up_log|sc_log|sc_warn|sc_err|echo|printf) ' <<< "$upgrade_lines" |
    grep -cE '(^|[;&|(]|then |do |else )[[:space:]]*(sc_in_dir [^ ]+ )?rm -[a-z]*[rf][a-z]* -- (public|legacy|cache)')"
# The www-data copy of the database password is removed whenever upgrade.sh ends, and at every start.
assert_eq "upgrade.sh removes the www-data options file on every exit, the entrypoint at every start and before Apache" "1 2" \
  "$(grep -c "^trap 'sc_db_cnf_www_drop' EXIT$" "$IMAGE_DIR/installer/upgrade.sh") $(grep -c '^sc_db_cnf_www_drop$' "$IMAGE_DIR/installer/entrypoint.sh")"
assert_eq "no chown in upgrade.sh names a path in the install: it runs in the folder it checked" "0" \
  "$(grep -vE '^[[:space:]]*(up_skip|up_failed|up_log|sc_log|sc_warn|sc_err|echo|printf) ' <<< "$upgrade_lines" |
    grep -cE '(^|[;&|(]|then |do |else )[[:space:]]*chown ')"

# --- the images -----------------------------------------------------------------
echo
echo "The SuiteCRM image"
if ! sc_image suitecrm; then
  fail "the SuiteCRM image builds or is on this machine"
else
  image="${SC_IMAGE[suitecrm]}"
  # in_image SCRIPT: runs a bash script in a container of the image that starts nothing else.
  in_image() { docker run --rm --name "${SC_PREFIX}look" --network none --entrypoint bash "$image" -c "$1" 2>&1; }

  assert_eq "the package is SuiteCRM $VERSION" "$VERSION" "$(in_image 'cat /clouve/suitecrm/app/VERSION')"
  # The build checks the zip against the Dockerfile's checksum before anything else (above), and then moves some PHP
  # libraries in it to fixed releases, so the kept zip no longer has upstream's checksum.
  assert_eq "the release zip is kept" "yes" "$(in_image "[ -s /clouve/suitecrm/SuiteCRM-$VERSION.zip ] && echo yes")"
  # The PHP libraries in the package that have a fixed release in their line (finding 6 of the image review). The
  # build takes each release from GitHub with its checksum, and patch-vendor.php records it where Composer would. The
  # kept zip, which SuiteCRM's own upgrade command unpacks, holds the same releases.
  fixed="mtdowling/jmespath.php=2.9.2 symfony/http-foundation=v6.4.49 symfony/yaml=v6.4.49 smarty/smarty=v4.5.8"
  fixed="$fixed guzzlehttp/guzzle=7.12.3 guzzlehttp/psr7=2.12.5 phpseclib/phpseclib=3.0.58"
  # versions_in app|zip|runtime: "name=version" for each package of $fixed, from installed.json in the package or in
  # the kept zip, or from Composer\InstalledVersions through the package's own autoloader.
  versions_in() {
    # shellcheck disable=SC2016  # PHP code
    docker run --rm --name "${SC_PREFIX}look" --network none --memory 1g -e "T_FIXED=$fixed" -e "T_WHERE=$1" \
      --entrypoint php "$image" -r '
        $app = "/clouve/suitecrm/app";
        if (getenv("T_WHERE") === "zip") {
            $zip = new ZipArchive();
            $zip->open(glob("/clouve/suitecrm/SuiteCRM-*.zip")[0]);
            $json = $zip->getFromName("vendor/composer/installed.json");
        } else {
            $json = file_get_contents("$app/vendor/composer/installed.json");
            require "$app/vendor/autoload.php";
        }
        $have = [];
        foreach (json_decode($json, true)["packages"] as $p) {
            $have[$p["name"]] = $p["version"];
        }
        $out = [];
        foreach (explode(" ", getenv("T_FIXED")) as $f) {
            $n = strstr($f, "=", true);
            $v = getenv("T_WHERE") === "runtime" ? Composer\InstalledVersions::getPrettyVersion($n) : ($have[$n] ?? null);
            $out[] = "$n=" . ($v ?? "missing");
        }
        echo implode(" ", $out);' 2>&1
  }
  assert_eq "the package has the fixed releases of its PHP libraries" "$fixed" "$(versions_in app)"
  assert_eq "and Composer's runtime record says so too" "$fixed" "$(versions_in runtime)"
  assert_eq "the kept release zip has the same ones" "$fixed" "$(versions_in zip)"
  # The build checks the release zip against SUITECRM_SHA256 before anything else, and unpacks the package from it.
  # Then it changes only the packages above and Composer's two records, in both places. So every file of the kept zip
  # is the package's file, apart from the keep-list, which the image patches in the package alone (patch-keep-list.sh).
  # shellcheck disable=SC2016  # PHP code
  assert_eq "every file in the kept zip is the same as the package's, the keep-list aside" "0 differ, 0 missing" \
    "$(docker run --rm --name "${SC_PREFIX}look" --network none --memory 1g --entrypoint php "$image" -r '
        $zip = new ZipArchive();
        $zip->open(glob("/clouve/suitecrm/SuiteCRM-*.zip")[0]);
        $differ = $missing = 0;
        for ($i = 0; $i < $zip->numFiles; $i++) {
            $s = $zip->statIndex($i);
            if (str_ends_with($s["name"], "/") || $s["name"] === "config/services/system/upgrades.yaml") {
                continue;
            }
            $file = "/clouve/suitecrm/app/" . $s["name"];
            if (!is_file($file)) {
                $missing++;
            } elseif (hexdec(hash_file("crc32b", $file)) !== ($s["crc"] & 0xffffffff) || filesize($file) !== $s["size"]) {
                $differ++;
            }
        }
        echo "$differ differ, $missing missing";' 2>&1)"
  # shellcheck disable=SC2016  # PHP code
  assert_eq "jmespath works through SuiteCRM's autoloader" "1" \
    "$(in_image 'php -r "require \"/clouve/suitecrm/app/vendor/autoload.php\"; echo JmesPath\\search(\"a.b\", [\"a\" => [\"b\" => 1]]);"')"
  # Root reads the image's version and size from the package and runs the installer next to it. So all of /clouve
  # is root's, and www-data, which runs SuiteCRM's own code, can change none of it. A new install copies the
  # package as www-data and sets upstream's modes on the volume (tests/suitecrm-entrypoint.test.sh).
  assert_eq "/clouve and everything under it is root's" "0" "$(in_image 'find /clouve ! -user root | wc -l')"
  assert_eq "and nothing there can be written by anyone else" "0" \
    "$(in_image 'find /clouve ! -type l -perm /g=w,o=w | wc -l')"
  assert_eq "www-data can read the package it installs from (folders 755, files 644, bin/console 755)" "0 0 755" "$(in_image '
    cd /clouve/suitecrm/app
    echo "$(find . -type d ! -perm 755 | wc -l) $(find . -type f ! -perm 0644 ! -path ./bin/console | wc -l)" \
      "$(stat -c %a bin/console)"')"
  # Apache's parent is root and opens its logs, PID file and lock files at every start and reload. The base image
  # gives these folders to www-data with mode 1777.
  assert_eq "Apache's log, run and lock folders are root's, mode 755" "root 755 root 755 root 755" \
    "$(in_image 'stat -c "%U %a" /var/log/apache2 /var/run/apache2 /var/lock/apache2 | xargs')"
  assert_eq "and nothing in them is anyone else's or open to writing" "0" \
    "$(in_image 'find /var/log/apache2 /var/run/apache2 /var/lock/apache2 \( ! -user root -o ! -type l -perm /g=w,o=w \) | wc -l')"
  assert_eq "the access and error logs still go to the container's output" "/dev/stdout /dev/stderr" \
    "$(in_image 'readlink /var/log/apache2/access.log /var/log/apache2/error.log | xargs')"
  assert_eq "the volume's mount point is www-data's and not open to everyone" "www-data 755" \
    "$(in_image 'stat -c "%U %a" /var/www/html')"
  keep="$(in_image "sed -n '/^    toKeep:/,/^    toKeepIgnore:/p' /clouve/suitecrm/app/config/services/system/upgrades.yaml")"
  for entry in clouve .suitecrm_initialized .suitecrm_url; do
    assert_eq "the package's keep-list has '$entry'" "1" "$(grep -c "^      - '$entry'\$" <<< "$keep")"
  done
  assert_eq "PHP is 8.3" "8.3" "$(in_image 'php -r "echo PHP_MAJOR_VERSION, \".\", PHP_MINOR_VERSION;"')"
  missing="$(in_image '
    for e in imap intl curl json gd mbstring mysqli pdo_mysql openssl soap xml zip ldap ctype iconv bcmath exif gettext "Zend OPcache"; do
      php -m | grep -qix "$e" || printf "%s " "$e"
    done')"
  assert_eq "PHP has imap and every extension SuiteCRM asks for" "" "$missing"
  assert_eq "PHP errors go to the container's log, not to a file www-data can't write" "" \
    "$(in_image 'php -r "echo ini_get(\"error_log\");"')"
  assert_eq "neither Composer nor git is in the image" "" "$(in_image 'command -v composer git')"
  # The base image keeps the compilers it built PHP with. The extensions are built by the end of the build, so
  # they go. Every extension must still load, with no library missing.
  assert_eq "no compiler or build tool is left" "" \
    "$(in_image 'command -v gcc g++ cc cpp c++ make autoconf re2c ld as dpkg-buildpackage | xargs')"
  assert_eq "PHP starts without a warning about an extension" "0" "$(in_image 'php -m 2>&1 | grep -ci "warning\|unable to load"')"
  assert_eq "no extension, and neither PHP nor Apache, misses a library" "0" "$(in_image '
    { for f in "$(php -r "echo ini_get(\"extension_dir\");")"/*.so "$(command -v php)" /usr/sbin/apache2 /usr/lib/apache2/modules/libphp.so; do ldd "$f"; done; } 2>&1 | grep -c "not found"')"
  assert_eq "the c-client library the imap extension needs is Debian 12's, and its header package is gone" "ii 8:2007f~dfsg-7 none" \
    "$(in_image 'echo "$(dpkg-query -W -f "\${db:Status-Abbrev}\${Version}" libc-client2007e | sed "s/+b[0-9]*$//" | tr -s " ") $(dpkg-query -W -f "\${db:Status-Abbrev}" libc-client2007e-dev 2>/dev/null | grep -q "^ii" && echo dev-installed || echo none)"')"
  assert_eq "imap_open is there" "yes" "$(in_image 'php -r "echo function_exists(\"imap_open\") ? \"yes\" : \"no\";"')"
  assert_contains "Apache's configuration is valid" "$(in_image 'apache2ctl -t 2>&1')" "Syntax OK"
  apache="$(in_image 'apache2ctl -M 2>/dev/null; grep -h "DocumentRoot" /etc/apache2/sites-enabled/*.conf; cat /etc/apache2/conf-enabled/clouve.conf')"
  for module in rewrite_module headers_module expires_module remoteip_module setenvif_module; do
    assert_contains "Apache loads $module" "$apache" " $module "
  done
  assert_contains "Apache serves /var/www/html/public" "$apache" "DocumentRoot /var/www/html/public"
  assert_contains "a forwarded HTTPS request turns HTTPS on" "$apache" 'SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on'
  assert_contains "the client's address comes from X-Forwarded-For" "$apache" "RemoteIPHeader X-Forwarded-For"
  assert_eq "only private peers are trusted to name it" "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16" \
    "$(sed -n 's/^RemoteIPInternalProxy //p' <<< "$apache" | tr '\n' ' ' | sed 's/ $//')"
  # Password-reset links and API tokens travel in query strings and in the Referer, and the access log is the
  # container's log. tests/suitecrm-entrypoint.test.sh reads a real log line.
  assert_eq "the access log's format has the method and the path, and neither the query string nor the Referer" \
    'LogFormat "%h %l %u %t \"%m %U %H\" %>s %O \"-\" \"%{User-Agent}i\"" combined' \
    "$(grep '^LogFormat .* combined$' <<< "$apache" | tail -n 1)"
  assert_eq "the error log's format has no Referer either" "1 0" \
    "$(grep -c '^ErrorLogFormat ' <<< "$apache") $(grep '^ErrorLogFormat ' <<< "$apache" | grep -ci referer)"
  assert_eq "the web root gives no folder listing" "1" \
    "$(sed -n '/^<Directory \/var\/www\/html\/public\/\?>/,/^<\/Directory>/p' <<< "$apache" | grep -c '^[[:space:]]*Options -Indexes')"
  assert_eq "the clouve-ops account, its sudo rule and the sshd drop-in are there" \
    "clouve-ops 440 root:root AllowUsers clouve-ops" "$(in_image '
      echo "$(id -un clouve-ops) $(stat -c "%a %U:%G" /etc/sudoers.d/clouve-ops)" \
        "$(grep "^AllowUsers" /etc/ssh/sshd_config.d/clouve-ops.conf)"')"
  assert_eq "the clouve-ops account has no password" "locked" \
    "$(in_image 'case "$(getent shadow clouve-ops | cut -d: -f2)" in "!"*|"*") echo locked ;; *) echo set ;; esac')"
  assert_eq "the persona at /clouve/context/suitecrm/CONTEXT.md.tpl is this checkout's" \
    "$(sha256sum < "$IMAGE_DIR/context/suitecrm/CONTEXT.md.tpl" | cut -d' ' -f1)" \
    "$(in_image 'sha256sum < /clouve/context/suitecrm/CONTEXT.md.tpl | cut -d" " -f1')"
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  in_tree="$(cd "$IMAGE_DIR/installer" && find . -type f | LC_ALL=C sort | xargs sha256sum)"
  assert_eq "the installer in the image is this checkout's" "$in_tree" \
    "$(in_image 'cd /clouve/suitecrm/installer && find . -type f | LC_ALL=C sort | xargs sha256sum')"
  assert_eq "its scripts can be run, and lib.sh is only sourced" "755 755 755 755 644" "$(in_image '
    cd /clouve/suitecrm/installer && stat -c %a entrypoint.sh install.sh upgrade.sh start-clouve-ops-sshd.sh lib.sh | tr "\n" " " | sed "s/ $//"')"
  assert_eq "its scripts for staff can be run too" "755 755 755" "$(in_image '
    cd /clouve/suitecrm/installer && stat -c %a build-id.sh release-scheduler.sh loops.sh | tr "\n" " " | sed "s/ $//"')"
  assert_eq "a build id is recorded" "yes" \
    "$(in_image 'grep -qE "^[0-9a-f]{16}$" /clouve/suitecrm/BUILD && echo yes')"
  # An upgrade that failed twice is tried again only by another build. So the id has to change with everything a
  # fix can be in: the installer, the Dockerfile, PHP's settings and Apache's configuration.
  assert_eq "the build id is what build-id.sh works out in the image" "same" \
    "$(in_image '[ "$(/clouve/suitecrm/installer/build-id.sh)" = "$(cat /clouve/suitecrm/BUILD)" ] && echo same')"
  assert_eq "it changes with the Dockerfile, with a PHP setting, with an Apache setting and with the installer" \
    "changed changed changed changed" "$(in_image '
      was=$(cat /clouve/suitecrm/BUILD); id=/clouve/suitecrm/installer/build-id.sh
      try() { [ "$($id)" != "$was" ] && printf "changed " || printf "same "; }
      echo "# a fix" >> /clouve/suitecrm/Dockerfile; try; sed -i "\$d" /clouve/suitecrm/Dockerfile
      echo "memory_limit = 513M" > /usr/local/etc/php/conf.d/zz-test.ini; try; rm /usr/local/etc/php/conf.d/zz-test.ini
      echo "# a fix" >> /etc/apache2/conf-available/clouve.conf; try; sed -i "\$d" /etc/apache2/conf-available/clouve.conf
      echo "# a fix" >> /clouve/suitecrm/installer/lib.sh; try' | sed 's/ $//')"
  # The upgrade's state file, on a folder with room for one page of data: a write that doesn't fit must fail and
  # leave the file as it was, phase included. Losing the phase would make the next start take a half-upgraded site
  # for one with nothing under way.
  state="$(docker run --rm --name "${SC_PREFIX}state" --network none --memory 1g \
    --tmpfs /var/www/html/tmp/clouve-backup:size=8k,mode=0700 --entrypoint bash "$image" -c '
      . /clouve/suitecrm/installer/lib.sh
      sc_state_set phase=upgrade from=8.9.1 to=8.10.2 attempts=1 reason=first || echo "first write failed"
      echo "mode=$(stat -c %a "$SC_STATE")"
      head -c 4000 /dev/zero > "$SC_STATE_DIR/fill" 2>/dev/null
      big=$(head -c 6000 /dev/zero | tr "\0" x)
      if sc_state_set "reason=$big" 2>/dev/null; then echo "write=reported-ok"; else echo "write=refused"; fi
      echo "phase=$(sc_state_get phase) reason=$(sc_state_get reason) attempts=$(sc_state_get attempts)"
      rm -f "$SC_STATE_DIR/fill"
      sc_state_set attempts=2 && echo "then=$(sc_state_get phase) $(sc_state_get attempts) $(sc_state_get reason)"' 2>&1 | xargs)"
  assert_eq "a state write that doesn't fit on the disk is refused, the file stays whole, and its mode is 600" \
    "mode=600 write=refused phase=upgrade reason=first attempts=1 then=upgrade 2 first" "$state"
  assert_eq "a state folder made in a set-group-ID tmp/ is root's with mode 700, and is trusted" "root 700 trusted" \
    "$(in_image '. /clouve/suitecrm/installer/lib.sh; mkdir -p /var/www/html/tmp && chown www-data:www-data /var/www/html/tmp && chmod 2755 /var/www/html/tmp
      sc_state_set phase=backup >/dev/null 2>&1; echo "$(stat -c "%U %a" "$SC_STATE_DIR") $(sc_state_dir_status)"')"
  assert_eq "a state folder of www-data's, a link in its place, and one that others can write in are not trusted" \
    "untrusted untrusted untrusted" "$(in_image '. /clouve/suitecrm/installer/lib.sh; mkdir -p /var/www/html/tmp /x
      mkdir "$SC_STATE_DIR" && chown www-data "$SC_STATE_DIR"; printf "%s " "$(sc_state_dir_status)"; rmdir "$SC_STATE_DIR"
      ln -s /x "$SC_STATE_DIR"; printf "%s " "$(sc_state_dir_status)"; rm "$SC_STATE_DIR"
      mkdir -m 770 "$SC_STATE_DIR"; sc_state_dir_status')"
  # sc_in_state runs a command inside the state folder it checked. A swap by www-data after the check changes
  # nothing for that command, and a folder that is not root's, or a link, is never entered (status 97).
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  assert_eq "a command run in the state folder keeps reading the folder it checked, while www-data swaps it" \
    "/var/www/html/tmp/clouve-backup phase=real 97 97 97" "$(in_image '. /clouve/suitecrm/installer/lib.sh
      mkdir -p /var/www/html/tmp && chown www-data:www-data /var/www/html/tmp
      mkdir -m 700 "$SC_STATE_DIR" && echo phase=real > "$SC_STATE"
      printf "%s " "$(sc_in_state pwd -P)"
      slow() { sleep 2; cat state; }
      sc_in_state slow > /tmp/out & sleep 0.5
      setpriv --reuid=www-data --regid=www-data --init-groups -- bash -c "cd /var/www/html/tmp && mv clouve-backup real && mkdir clouve-backup && echo phase=forged > clouve-backup/state"
      wait; printf "%s " "$(cat /tmp/out)"
      sc_in_state true; printf "%s " "$?"
      rm -rf "$SC_STATE_DIR"; ln -s /root "$SC_STATE_DIR"; sc_in_state true; printf "%s " "$?"
      rm "$SC_STATE_DIR"; mkdir -m 777 "$SC_STATE_DIR"; sc_in_state true; echo "$?"' 2>&1 | tail -n 1)"
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  assert_eq "a command run in an install folder runs only where that folder really is, never behind a link" \
    "/var/www/html/public/legacy 97 97" "$(in_image '. /clouve/suitecrm/installer/lib.sh
      mkdir -p /var/www/html/public/legacy && printf "%s " "$(sc_in_dir public/legacy pwd -P)"
      rm -rf /var/www/html/public && ln -s /clouve/suitecrm/app/public /var/www/html/public
      sc_in_dir public/legacy true; printf "%s " "$?"; sc_in_dir public true; echo "$?"' 2>&1 | tail -n 1)"
  # www-data can move tmp/, with root's state folder in it, into the folder that root is emptying. sc_clear checks
  # that the state folder is at its place first, lets www-data remove, gives what is left to www-data except the
  # state folder (by its inode), and stops when anything is left.
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  assert_eq "emptying a folder that www-data moved tmp/ into stops, and root's state folder keeps its backup" \
    "refused kept root 700 | handed-over kept root 700 www-data" "$(in_image '. /clouve/suitecrm/installer/lib.sh
      w() { setpriv --reuid=www-data --regid=www-data --init-groups -- "$@"; }
      mkdir -p /var/www/html/tmp /var/www/html/public/legacy/x && chown -R www-data:www-data /var/www/html
      mkdir -m 700 "$SC_STATE_DIR" "$SC_STATE_DIR/8.10.2-to-8.10.3" && echo dump > "$SC_STATE_DIR/8.10.2-to-8.10.3/db.sql.gz"
      w bash -c "cd /var/www/html && mv tmp public/legacy/moved && mkdir tmp"
      sc_clear public/legacy ! -name upload && printf "removed " || printf "refused "
      kept() { [ -s /var/www/html/public/legacy/moved/clouve-backup/8.10.2-to-8.10.3/db.sql.gz ] && printf "kept %s | " "$(stat -c "%U %a" /var/www/html/public/legacy/moved/clouve-backup)"; }
      kept
      ino="$(stat -c %i /var/www/html/public/legacy/moved/clouve-backup) $(stat -c %i /var/www/html/public/legacy/moved)"
      touch /var/www/html/public/legacy/x/rootfile
      sc_in_dir public/legacy sc_hand_over "$ino" ! -name upload && printf "handed-over "
      kept | sed "s/ | $//"; printf " %s" "$(stat -c %U /var/www/html/public/legacy/x/rootfile)"' 2>&1 | tail -n 1)"
  # The same move in the middle of sc_clear, after www-data's first pass: sc_as_www moves tmp/ in right after it
  # runs. tmp/ holds root's other folders too, such as the suitecrm skill's backups. The hand-over leaves tmp/ and
  # everything of root's in it alone, and sc_clear stops.
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  assert_eq "when www-data moves tmp/ in during the removal, every folder of root's in tmp/ stays root's and whole" \
    "1 | root 700 state | root 700 COMPLETE db.sql.gz" "$(in_image '. /clouve/suitecrm/installer/lib.sh
      R=/var/www/html; chown www-data:www-data "$R"
      install -d -o www-data -g www-data "$R/tmp" "$R/public" "$R/public/legacy" "$R/public/legacy/upload" "$R/public/legacy/modules"
      mkdir -m 700 "$R/tmp/clouve-backup"; echo phase=restore > "$R/tmp/clouve-backup/state"
      b="$R/tmp/clouve-skill-backups/20261116-100000"; mkdir -m 700 "$R/tmp/clouve-skill-backups" "$b"; echo dump > "$b/db.sql.gz"; echo ok > "$b/COMPLETE"
      calls=0
      sc_as_www() { calls=$((calls + 1)); setpriv --reuid=www-data --regid=www-data --init-groups -- "$@"; local rc=$?
        [ "$calls" = 1 ] && setpriv --reuid=www-data --regid=www-data --init-groups -- sh -c "mv $R/tmp $R/public/legacy/moved && mkdir $R/tmp"; return $rc; }
      sc_clear public/legacy ! -name upload; printf "%s | " "$?"
      m=$R/public/legacy/moved
      printf "%s %s | " "$(stat -c "%U %a" "$m/clouve-backup" 2>&1)" "$(ls "$m/clouve-backup" 2>&1 | xargs)"
      echo "$(stat -c "%U %a" "$m/clouve-skill-backups/20261116-100000" 2>&1) $(ls "$m/clouve-skill-backups/20261116-100000" 2>&1 | xargs)"' 2>&1 | tail -n 1)"
  # A folder that www-data can't write (root's 755 after a command run as root, or www-data's own 555) is emptied all
  # the same: sc_clear gives the folder itself to www-data and opens it to its owner, from inside it.
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  assert_eq "a folder that www-data can't write is emptied all the same" "root-755: 0 upload | www-555: 0 upload" \
    "$(in_image '. /clouve/suitecrm/installer/lib.sh
      R=/var/www/html; out=""
      for variant in root-755 www-555; do
        rm -rf "${R:?}"/* 2>/dev/null; chown www-data:www-data "$R"
        install -d -o www-data -g www-data "$R/tmp" "$R/public" "$R/public/legacy" "$R/public/legacy/upload" "$R/public/legacy/modules"
        echo code > "$R/public/legacy/index.php"; chown www-data:www-data "$R/public/legacy/index.php"
        mkdir -m 700 "$R/tmp/clouve-backup"; echo phase=restore > "$R/tmp/clouve-backup/state"
        case $variant in root-755) chown root:root "$R/public/legacy" ;; www-555) chmod 555 "$R/public/legacy" ;; esac
        sc_clear public/legacy ! -name upload; out="$out$variant: $? $(ls -A "$R/public/legacy" | xargs) | "
      done; echo "${out% | }"' 2>&1 | tail -n 1)"
  # A second run of upgrade.sh that is refused the lock leaves the running one's options file alone.
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  assert_eq "a run of upgrade.sh that doesn't get the lock leaves the www-data options file of the run that has it" \
    "1 root www-data 640" "$(in_image '. /clouve/suitecrm/installer/lib.sh
      install -d -m 700 /run/clouve; printf "[client]\nuser=x\n" > /run/clouve/db.cnf; chmod 600 /run/clouve/db.cnf
      sc_db_cnf_www; flock /run/clouve/upgrade.lock sleep 20 & sleep 1
      DATABASE_HOST=db DATABASE_NAME=suitecrm DATABASE_USER=u DATABASE_PASSWORD=p /clouve/suitecrm/installer/upgrade.sh --finish-as-is > /dev/null 2>&1
      echo "$? $(stat -c "%U %G %a" /run/clouve-www/db.cnf 2>&1)"; kill %1 2>/dev/null' 2>&1 | tail -n 1)"
  # When the state folder is not at tmp/clouve-backup but a folder of root's of that name is elsewhere on the volume
  # (tmp/ was moved with it inside), the start says where, quoted, and what to do.
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  assert_eq "a state folder that www-data moved away with tmp/ is named, quoted, with what staff do" "named do" \
    "$(in_image '. /clouve/suitecrm/installer/lib.sh
      R=/var/www/html; install -d -o www-data -g www-data "$R/public/legacy/a b;x" "$R/tmp"
      mkdir -m 700 "$R/public/legacy/a b;x/clouve-backup"
      note=$(sc_moved_state_note)
      case $note in *"public/legacy/a\ b\;x/clouve-backup"*) printf "named " ;; esac
      case $note in *"move the tmp/ that holds the state folder back"*) echo do ;; *) echo none ;; esac' 2>&1 | tail -n 1)"
  # The folders that sc_state_dir_vet moved aside have names of one shape. Any other name in tmp/ that starts like
  # one is www-data's own and is never put into a command for staff to run; the one that is, is quoted.
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  assert_eq "only names of the image's own shape count as moved-aside folders, and the put-back command quotes them" \
    "clouve-backup.untrusted-20261116T101500Z clouve-backup.untrusted-20261116T101500Z-2 | odd: 1 | safe" "$(in_image '. /clouve/suitecrm/installer/lib.sh
      mkdir -p /var/www/html/tmp && cd /var/www/html/tmp
      bad='"'"'clouve-backup.untrusted-0;touch${IFS}$HOME.sct-pwned;#'"'"'
      mkdir clouve-backup.untrusted-20261116T101500Z clouve-backup.untrusted-20261116T101500Z-2 "$bad"
      printf "%s | odd: %s | " "$(sc_untrusted_dirs | sed "s|.*/||" | xargs)" "$(sc_odd_dirs | grep -c .)"
      cmd=$(sc_put_back_command "$bad"); cmd=${cmd#*run: }; bash -c "$cmd" >/dev/null 2>&1
      [ -e /root.sct-pwned ] && echo pwned || echo safe' 2>&1 | tail -n 1)"
  # Apache and PHP don't say which versions they are (security.conf is Debian's; a drop-in named clouve.conf
  # loads before it and would lose to it).
  assert_eq "Apache names no version and signs no page, and PHP doesn't announce itself" "Prod Off 0" \
    "$(in_image 'echo $(grep -h "^ServerTokens" /etc/apache2/conf-enabled/*.conf | tail -n 1 | cut -d" " -f2) $(grep -h "^ServerSignature" /etc/apache2/conf-enabled/*.conf | tail -n 1 | cut -d" " -f2) $(php -r "echo (int) ini_get(\"expose_php\");")')"
  assert_eq "PHP's sessions take no id they didn't make, and a stack trace carries no arguments" "1 1" \
    "$(in_image 'php -r "echo (int) ini_get(\"session.use_strict_mode\"), \" \", (int) ini_get(\"zend.exception_ignore_args\");"')"
  # The clouve-ops sshd: no forwarding of any kind, and sign-ins logged to the container's log.
  sshd_t="$(in_image 'ssh-keygen -A >/dev/null 2>&1; mkdir -p /run/sshd; sshd -T -C user=clouve-ops,host=x,addr=127.0.0.1 2>&1')"
  fwd=''
  for key in disableforwarding permittunnel; do fwd="$fwd$(grep "^$key " <<< "$sshd_t")|"; done
  assert_eq "the clouve-ops sshd forwards nothing" "disableforwarding yes|permittunnel no|" "$fwd"
  assert_eq "it logs at INFO, to the container's log" "loglevel INFO 1" \
    "$(grep '^loglevel ' <<< "$sshd_t") $(in_image 'grep -c "^exec /usr/sbin/sshd -D -e$" /clouve/suitecrm/installer/start-clouve-ops-sshd.sh')"
  # Only sudo (clouve-ops) and unix_chkpwd (PAM) keep a set-user-ID or set-group-ID bit.
  assert_eq "no program but sudo and unix_chkpwd has a set-user-ID or set-group-ID bit" "/usr/bin/sudo /usr/sbin/unix_chkpwd" \
    "$(in_image 'find / -xdev -perm /6000 -type f 2>/dev/null | sort | xargs')"
  assert_eq "the entrypoint and the command are the image's" \
    '["/clouve/suitecrm/installer/entrypoint.sh"] ["apache2-foreground"]' \
    "$(docker image inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")"
fi

echo
echo "The database image"
if ! sc_image suitecrm-mariadb; then
  fail "the database image builds or is on this machine"
else
  db_image="${SC_IMAGE[suitecrm-mariadb]}"
  in_db_image() { docker run --rm --name "${SC_PREFIX}dblook" --network none --entrypoint bash "$db_image" -c "$1" 2>&1; }
  assert_contains "the server is MariaDB 12.3" "$(in_db_image 'mariadbd --version')" " 12.3."
  assert_eq "tini runs the wrapper, which runs mariadbd" \
    '["/usr/bin/tini","--","/usr/local/bin/clouve-entrypoint.sh"] ["mariadbd"]' \
    "$(docker image inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$db_image")"
  assert_contains "MARIADB_AUTO_UPGRADE=1 is in the image's environment" \
    "$(docker image inspect --format '{{json .Config.Env}}' "$db_image")" '"MARIADB_AUTO_UPGRADE=1"'
  assert_eq "the clouve-ops account has no password" "locked" \
    "$(in_db_image 'case "$(getent shadow clouve-ops | cut -d: -f2)" in "!"*|"*") echo locked ;; *) echo set ;; esac')"
  # The base image's environment names the gosu it shipped. This image replaces that gosu with a rebuilt one.
  assert_eq "the environment names the version of the gosu that is in the image" "same" \
    "$(in_db_image 'case "$(gosu --version)" in "$GOSU_VERSION "*) echo same ;; *) echo "GOSU_VERSION=$GOSU_VERSION, gosu is $(gosu --version)" ;; esac')"
  assert_eq "the sshd drop-in is root's, and only root can write it" "root:root 644" \
    "$(in_db_image 'stat -c "%U:%G %a" /etc/ssh/sshd_config.d/clouve-ops.conf')"
  db_sshd_t="$(in_db_image 'ssh-keygen -A >/dev/null 2>&1; mkdir -p /run/sshd; sshd -T -C user=clouve-ops,host=x,addr=127.0.0.1 2>&1')"
  fwd=''
  for key in disableforwarding permittunnel loglevel; do fwd="$fwd$(grep "^$key " <<< "$db_sshd_t")|"; done
  assert_eq "its clouve-ops sshd forwards nothing and logs at INFO, to the container's log" \
    "disableforwarding yes|permittunnel no|loglevel INFO|1" \
    "$fwd$(in_db_image 'grep -c "^exec /usr/sbin/sshd -D -e$" /usr/local/bin/start-clouve-ops-sshd.sh')"
  assert_eq "no program but sudo and unix_chkpwd has a set-user-ID or set-group-ID bit" "/usr/bin/sudo /usr/sbin/unix_chkpwd" \
    "$(in_db_image 'find / -xdev -perm /6000 -type f 2>/dev/null | sort | xargs')"
  # The official entrypoint makes root@'%' unless MARIADB_ROOT_HOST says otherwise. Nothing signs in as root over
  # the network: the rotation Job signs in as the app's user, and staff use the socket.
  assert_contains "a new data directory gets root for localhost only (MARIADB_ROOT_HOST=localhost)" \
    "$(docker image inspect --format '{{json .Config.Env}}' "$db_image")" '"MARIADB_ROOT_HOST=localhost"'
  # The base's security updates are in (USN-9065-1 fixed glibc in 2.39-0ubuntu8.12).
  assert_eq "glibc has the base release's security updates" "yes" \
    "$(in_db_image 'dpkg --compare-versions "$(dpkg-query -W -f "\${Version}" libc6)" ge 2.39-0ubuntu8.12 && echo yes || dpkg-query -W -f "\${Version}" libc6')"
fi

# --- no SSH host key and no password in any layer --------------------------------
# docker save writes every layer of the image. A file that a later layer deleted is still in the layer that made it,
# so this reads all of them. The scan prints the paths it finds, one per line.
host_keys_in_layers() {
  docker save "$1" | python3 -I -c '
import sys, tarfile
found = set()
outer = tarfile.open(fileobj=sys.stdin.buffer, mode="r|")
for member in outer:
    blob = outer.extractfile(member) if member.isfile() else None
    if blob is None:
        continue
    try:
        layer = tarfile.open(fileobj=blob, mode="r|*")
        for entry in layer:
            name = entry.name.lstrip("./")
            if name.startswith("etc/ssh/ssh_host_"):
                found.add(name)
    except (tarfile.TarError, EOFError, OSError):
        continue
for name in sorted(found):
    print(name)
'
}
# secrets_in_history IMAGE: the build steps and environment entries that name a password, a secret or a token.
secrets_in_history() {
  { docker history --no-trunc --format '{{.CreatedBy}}' "$1"
    docker image inspect --format '{{range .Config.Env}}ENV {{println .}}{{end}}' "$1"
  } | grep -iE 'passw(or)?d[A-Za-z_]*=|secret[A-Za-z_]*=|token[A-Za-z_]*=|chpasswd|-p[^ ]*pass' || true
}
echo
echo "Layers and build history"
for name in suitecrm suitecrm-mariadb; do
  ref="${SC_IMAGE[$name]:-}"
  [ -n "$ref" ] && docker image inspect "$ref" >/dev/null 2>&1 || continue
  assert_eq "$name: no layer holds an SSH host key" "" "$(host_keys_in_layers "$ref")"
  assert_eq "$name: no build step and no environment entry names a password" "" "$(secrets_in_history "$ref")"
done

# --- the database wrapper and the data directory's MariaDB line --------------------
if [ -n "${SC_IMAGE[suitecrm-mariadb]:-}" ] && docker image inspect "${SC_IMAGE[suitecrm-mariadb]}" >/dev/null 2>&1; then
  echo
  echo "The database wrapper"
  db_image="${SC_IMAGE[suitecrm-mariadb]}"
  D="${SC_PREFIX}db"
  V="${SC_PREFIX}dbdata"
  ROOT_PW="root-pw-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  sc_new_disk "$V"
  start_db() {
    docker rm -f "$D" >/dev/null 2>&1
    docker run -d --name "$D" --network none --memory 1g -v "$V:/var/lib/mysql" \
      -e MYSQL_DATABASE=suitecrm -e MYSQL_USER=suitecrm -e "MYSQL_PASSWORD=$ROOT_PW-u" -e "MYSQL_ROOT_PASSWORD=$ROOT_PW" \
      "$db_image" >/dev/null
  }
  db_answers() { docker exec "$D" healthcheck.sh --connect --innodb_initialized; }
  # set_line VERSION: writes the data directory's recorded version, as the server's own user.
  set_line() {
    docker run --rm --network none -v "$V:/v" "$SC_SHAPER" \
      sh -c 'printf "%s\n" "$1" > /v/mariadb_upgrade_info && chown "$(stat -c %u:%g /v/ibdata1)" /v/mariadb_upgrade_info' _ "$1"
  }
  recorded() { docker run --rm --network none -v "$V:/v:ro" "$SC_SHAPER" cat /v/mariadb_upgrade_info 2>/dev/null; }

  start_db
  if sc_wait_for 120 db_answers; then
    pass "on a new disk the server starts"
  else
    fail "on a new disk the server starts"
    docker logs --tail 15 "$D" 2>&1 | sed 's/^/       | /'
  fi
  assert_eq "PID 1 is tini" "tini" "$(sc_pid1 "$D")"
  first="$(recorded)"
  assert_contains "the data directory records the server's version" "$first" "12.3."
  assert_eq "root is an account for localhost only" "localhost" \
    "$(sc_sql "$D" mysql "SELECT GROUP_CONCAT(host ORDER BY host) FROM mysql.global_priv WHERE user = 'root'")"
  docker stop -t 30 "$D" >/dev/null 2>&1

  set_line "13.0.2-MariaDB"
  start_db
  sc_wait_for 60 bash -c "! [ \"\$(docker inspect --format '{{.State.Running}}' $D 2>/dev/null)\" = true ]"
  log="$(docker logs "$D" 2>&1)"
  assert_eq "a data directory from MariaDB 13.0 stops the container" "false" \
    "$(docker inspect --format '{{.State.Running}}' "$D" 2>/dev/null)"
  if [ "$(docker inspect --format '{{.State.ExitCode}}' "$D" 2>/dev/null)" != 0 ]; then
    pass "with a failing exit status"
  else
    fail "with a failing exit status"
  fi
  assert_contains "the log says which versions don't fit" "$log" "13.0.2-MariaDB"
  assert_contains "and that the image is older" "$log" "refusing to start"
  assert_lacks "the server was never started on it" "$log" "ready for connections"
  assert_eq "the recorded version is left as it was" "13.0.2-MariaDB" "$(recorded)"

  set_line "12.1.2-MariaDB"
  start_db
  if sc_wait_for 180 db_answers; then
    pass "a data directory from MariaDB 12.1 starts"
  else
    fail "a data directory from MariaDB 12.1 starts"
    docker logs --tail 15 "$D" 2>&1 | sed 's/^/       | /'
  fi
  sc_wait_for 60 bash -c "docker run --rm --network none -v $V:/v:ro $SC_SHAPER grep -q '^12\.3\.' /v/mariadb_upgrade_info"
  assert_eq "and the automatic upgrade records the new version" "$first" "$(recorded)"
  assert_eq "the root password is in no log line" "0" "$(sc_count_secrets_in_log "$D" "$ROOT_PW")"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sSuiteCRM image checks passed.%s\n' "$SC_GREEN" "$SC_RESET"
  exit 0
fi
printf '%sSuiteCRM image checks failed.%s\n' "$SC_RED" "$SC_RESET"
exit 1
