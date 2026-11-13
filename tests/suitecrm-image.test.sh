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
#   - the installer in the image is this checkout's, and a build id is recorded.
#
# The database image:
#   - the Dockerfile builds on mariadb:12.3 and sets MARIADB_AUTO_UPGRADE=1;
#   - tini is PID 1's program, gosu is the rebuilt one and the environment
#     names its real version, no layer holds an SSH host key, the sshd drop-in
#     is root's alone to write, and the clouve-ops account has no password;
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
  assert_eq "the release zip is kept, with the Dockerfile's checksum" "$SHA256" \
    "$(in_image "sha256sum /clouve/suitecrm/SuiteCRM-$VERSION.zip | cut -d' ' -f1")"
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
