#!/bin/bash
# SC2016: values here hold a $ on purpose (bash -c scripts). SC2329: the traps run helpers.
# shellcheck disable=SC2016,SC2329

# ============================================================================
# The ownCloud image's start never follows www-data's links on the data volume
# ============================================================================
# The entrypoint wrapper runs as root and keeps the last domain it saw in
# /mnt/data/.owncloud_domain, on the data volume, which belongs to www-data.
# Before this test's fix it read the marker with cat and printed it in the
# log ("Previous domain from marker", "Old domain"), then wrote it with echo >,
# so a link there put any file root can read into the log and made root write
# wherever it pointed; a pipe there held the start forever.
#
# ownCloud's own start (/etc/owncloud.d/25-chown.sh, run as root at every
# start) gave everything under /mnt/data to www-data:root with find | xargs
# chown, without -h: a link of www-data's there gave its target, any file of
# root's in the container, to www-data. The image replaces that script with
# Clouve's installer/25-chown.sh (find -P ... -execdir chown -h).
#
# Static cases, no Docker: the wrapper sources root-paths.sh (the same file as
# the Gibbon image's), reads the marker only through safe_read, writes it only
# with safe_write, prints the old domain only when it looks like a host name,
# runs occ only without CLOUVE_OPS_PASSWORD and ends www-data's processes
# after it (reap_www_data, the Gibbon image's www-data.sh functions), and the
# Dockerfile copies the helpers; no script runs runuser or setpriv with
# CLOUVE_OPS_PASSWORD in reach; Clouve's 20-config.sh and 45-php.sh write the
# config folder's files only with safe_put, and the Dockerfile checks
# upstream's two scripts against their checksums; Clouve's 25-chown.sh has chown only
# with -h, no xargs, and find -P with -execdir; the Dockerfile checks
# upstream's script against its checksum before it puts Clouve's in its place.
# In the image: Clouve's 25-chown.sh is installed, upstream's is kept with that
# checksum, and both run on copies of one made-up volume: real files and
# folders end with the same owner, group and mode, and with Clouve's nothing a
# link points to changes (with upstream's it does: the control). Upstream's and
# Clouve's 20-config.sh and 45-php.sh write the same two files (content, owner,
# mode), and with Clouve's a link at either name leaves its target alone.
# Helper cases in the image (its coreutils): safe_write replaces a link and
# leaves its target as it was, safe_read and in_folder refuse a link, and a
# folder reached through a link isn't written.
# Docker cases: ownCloud, MariaDB and Redis from the three images with no
# network (one network namespace), a new install, then the app container
# restarts after each of these, planted by www-data:
#   - nothing: the marker holds the domain, no warning;
#   - the marker a link to a root-only file holding a stand-in secret shaped
#     like a host name: the secret isn't in the log, the file keeps its content
#     and mode, the marker is a regular file holding the domain, and the log
#     names the marker;
#   - the marker holding text that isn't a host name (a fake log line): the
#     text isn't in the log, the log names the marker;
#   - the marker holding an older domain: the domain change runs as before
#     (the log shows the old domain, occ sets overwrite.cli.url);
#   - a file and a folder of root's in the volume, and links of www-data's to
#     root's files and a folder in /etc, at the top and two levels down: the
#     targets keep their owner, group and mode, and root's file and folder
#     become www-data:root with their modes, as before;
#   - overwrite.config.php and objectstore.config.php (which ownCloud's own
#     start writes as root with gomplate, in /etc/owncloud.d/20-config.sh and
#     45-php.sh; the image runs Clouve's copies of both) as links to root's
#     files in /etc, then as dangling links (with leftovers of a cut-off write
#     beside them), then as pipes: the targets keep content, owner and mode,
#     nothing is made where a link pointed, the start finishes, both names are
#     regular files written by the start, and a leftover temporary file is
#     removed while a link at such a name is left;
#   - the marker a pipe, and then a link to a folder: the start finishes, and
#     the marker is a regular file again;
#   - the config folder swapped for a link to a folder of root's outside the
#     volume: nothing is written there, and the start stops with a line that
#     names the folder (put back, the next start finishes).
#
# --image NAME=REF (owncloud, owncloud-mariadb, owncloud-redis) picks the
# images; the default is r.clv.zone/e2eorg/<name>:latest, as ./build.sh
# owncloud tags them. --no-docker runs only the static cases. Containers and
# volumes are named ocdm-<pid>-* and removed at the end. Needs Docker for the
# rest.
#
# Usage: bash tests/owncloud-domain-marker.test.sh [--image NAME=REF]... [--no-docker]
#   Exit status: 0 when every check passes, 1 when one fails, 2 when the test
#   can't run (no image, Docker missing).
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
APPDIR="$REPO/apps/owncloud/image"
ENTRYPOINT="$APPDIR/installer/entrypoint.sh"
LIB="$APPDIR/installer/root-paths.sh"
PREFIX="ocdm-$$-"

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/^ *can.t run/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

declare -A IMAGE=([owncloud]=r.clv.zone/e2eorg/owncloud:latest
  [owncloud-mariadb]=r.clv.zone/e2eorg/owncloud-mariadb:latest [owncloud-redis]=r.clv.zone/e2eorg/owncloud-redis:latest)
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
PASSES=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=$((FAILED + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

if [ "$DOCKER" = true ] && { ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; }; then
  echo "This test needs Docker (or --no-docker)." >&2
  exit 2
fi

WORK="$(mktemp -d)"
chmod 700 "$WORK"
cleanup() {
  local name
  if [ "$DOCKER" = true ]; then
    while IFS= read -r name; do
      case "$name" in "$PREFIX"*) docker rm -f -v "$name" >/dev/null 2>&1 ;; esac
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
    while IFS= read -r name; do
      case "$name" in "$PREFIX"*) docker volume rm -f "$name" >/dev/null 2>&1 ;; esac
    done < <(docker volume ls --format '{{.Name}}' 2>/dev/null)
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ----------------------------------------------------------------------------
echo "Static cases"
# ----------------------------------------------------------------------------
code() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$1"; }
ep="$(code "$ENTRYPOINT")"
if [ -f "$LIB" ] && cmp -s "$LIB" "$REPO/apps/gibbon/image/installer/root-paths.sh"; then
  pass "installer/root-paths.sh is the Gibbon image's file"
else
  fail "installer/root-paths.sh is the Gibbon image's file"
fi
check "the Dockerfile copies root-paths.sh next to the entrypoint" \
  grep -qE '^COPY installer/root-paths.sh /clouve/app/installer/root-paths.sh' "$APPDIR/Dockerfile"
check "the wrapper sources root-paths.sh" grep -qE '^[[:space:]]*(\.|source) /clouve/app/installer/root-paths.sh' <<< "$ep"
assert_eq "no cat, head or read of the marker by its name" "" \
  "$(grep -nE '(cat|head|tail|read)[^|]*"?\$DOMAIN_MARKER' <<< "$ep" | grep -v 'safe_read')"
assert_eq "no >, >>, tee or touch writes the marker" "" \
  "$(grep -nE '(>>?|tee|touch)[[:space:]]*"?\$DOMAIN_MARKER' <<< "$ep")"
check "the marker is read with safe_read" grep -qE 'safe_read "\$DOMAIN_MARKER"' <<< "$ep"
check "the marker is written with safe_write" grep -qF 'safe_write "$DOMAIN_MARKER" "$OWNCLOUD_DOMAIN"' <<< "$ep"
check "the old domain is checked for a host name's shape" grep -qF 'looks_like_host' <<< "$ep"
CHOWN="$APPDIR/installer/25-chown.sh"
if [ ! -f "$CHOWN" ]; then
  fail "installer/25-chown.sh (Clouve's copy of ownCloud's chown step) exists"
else
  ch="$(code "$CHOWN")"
  assert_eq "25-chown.sh: every chown has -h (it never follows a link)" "" \
    "$(grep -nE '(^|[[:space:]])chown[[:space:]]' <<< "$ch" | grep -vE 'chown -h |^[0-9]+:[[:space:]]*echo ')"
  assert_eq "25-chown.sh: no xargs (a full path is followed through a folder swapped for a link)" "" \
    "$(grep -n 'xargs[^)]*chown' <<< "$ch")"
  assert_eq "25-chown.sh: every find that chowns walks with -P and runs chown with -execdir" "" \
    "$(grep -nE 'chown' <<< "$ch" | grep -E 'find' | grep -vE 'find -P .*-execdir chown -h ')"
fi
df="$(code "$APPDIR/Dockerfile")"
check "the Dockerfile checks upstream's 25-chown.sh against its checksum before replacing it" \
  grep -qE 'sha256sum -c' <<< "$(grep -E 'owncloud.d/25-chown.sh|UPSTREAM_CHOWN_SHA256' <<< "$df")"
check "the Dockerfile puts Clouve's 25-chown.sh in its place" \
  grep -qE '^COPY installer/25-chown.sh /etc/owncloud.d/25-chown.sh' <<< "$df"
for step in 20-config 45-php; do
  f="$APPDIR/installer/$step.sh"
  if [ ! -f "$f" ]; then
    fail "installer/$step.sh (Clouve's copy of ownCloud's $step step) exists"
    continue
  fi
  assert_eq "$step.sh: gomplate writes nothing into the config folder by its path" "" \
    "$(code "$f" | grep -nE -- '-o[[:space:]]+"?\$\{?OWNCLOUD_VOLUME_CONFIG')"
  if grep -qF "/etc/owncloud.d/$step.sh\" | sha256sum -c" "$APPDIR/Dockerfile" &&
      grep -qE "^COPY installer/$step.sh /etc/owncloud.d/$step.sh" "$APPDIR/Dockerfile"; then
    pass "the Dockerfile checks upstream's $step.sh against its checksum and puts Clouve's in its place"
  else
    fail "the Dockerfile checks upstream's $step.sh against its checksum and puts Clouve's in its place"
  fi
done
check "20-config.sh writes overwrite.config.php with safe_put" \
  grep -qF 'safe_put "${OWNCLOUD_VOLUME_CONFIG}/overwrite.config.php"' "$APPDIR/installer/20-config.sh"
check "45-php.sh writes objectstore.config.php with safe_put" \
  grep -qF 'safe_put "${OWNCLOUD_VOLUME_CONFIG}/objectstore.config.php"' "$APPDIR/installer/45-php.sh"
assert_eq "the wrapper runs occ only without CLOUVE_OPS_PASSWORD" "" \
  "$(grep -nE '/usr/bin/occ[[:space:]]' <<< "$ep" | grep -vE 'env -u CLOUVE_OPS_PASSWORD /usr/bin/occ ')"
check "the wrapper ends www-data's processes after its occ calls, before ownCloud's own start" \
  grep -qE '^[[:space:]]*reap_www_data "the domain update" \|\| exit 1[[:space:]]*$' <<< "$ep"
assert_eq "every reap_www_data call of the image is a statement of its own: reap_www_data \"...\" || exit 1" "" \
  "$(for f in "$APPDIR"/installer/*.sh; do [ "${f##*/}" = www-data.sh ] && continue; code "$f" |
       grep -nE 'reap_www_data[[:space:]]+"' | grep -vE '^[0-9]+:[[:space:]]*reap_www_data "[^"$()|]*" \|\| exit 1[[:space:]]*$' |
       sed "s|^|${f##*/}:|"; done)"
assert_eq "the reap comes right after the last occ call" "" "$(awk '
  /^[[:space:]]*(#|$)/ { next }
  want { if ($0 !~ /^[[:space:]]*reap_www_data "/) print NR ": " $0; want = 0 }
  /occ config:system:set trusted_domains 1 / { want = 1 }' "$ENTRYPOINT")"
assert_eq "root-paths.sh's mode check takes what stat %a prints for any mode (1 to 4 digits)" "" \
  "$(grep -nE '\^\[0-7\]\{3,4\}\$' "$LIB")"
assert_eq "no script of the image runs runuser or setpriv with CLOUVE_OPS_PASSWORD in reach" "" \
  "$(for f in "$APPDIR"/installer/*.sh; do code "$f" |
       grep -nE '(^|[[:space:]/])(runuser|setpriv)[[:space:]]' | grep -vE 'env -(u CLOUVE_OPS_PASSWORD|i)[^|;]*(runuser|setpriv)' |
       sed "s|^|${f##*/}:|"; done)"
if [ -f "$APPDIR/installer/www-data.sh" ] &&
    cmp -s <(sed -n '/^# _www_data_live UID:/,$p' "$APPDIR/installer/www-data.sh") \
      <(sed -n '/^# _www_data_live UID:/,$p' "$REPO/apps/gibbon/image/installer/www-data.sh"); then
  pass "www-data.sh's functions are the Gibbon image's, word for word"
else
  fail "www-data.sh's functions are the Gibbon image's, word for word"
fi

# ----------------------------------------------------------------------------
if [ "$DOCKER" = true ]; then
# ----------------------------------------------------------------------------
for name in owncloud owncloud-mariadb owncloud-redis; do
  if ! docker image inspect "${IMAGE[$name]}" >/dev/null 2>&1; then
    echo "The image ${IMAGE[$name]} isn't on this machine (./build.sh owncloud, or --image $name=REF)." >&2
    exit 2
  fi
done

echo
echo "Helper cases in the image (${IMAGE[owncloud]})"
helper="$(docker run --rm --pull=never --network none --user 0 --entrypoint bash "${IMAGE[owncloud]}" -c '
  [ -f /clouve/app/installer/root-paths.sh ] || { echo "no helper"; exit 0; }
  . /clouve/app/installer/root-paths.sh
  mkdir -p /srv/t/u /srv/t/real; cd /srv/t
  umask 077; printf "secret\n" > target; umask 022
  ln -s /srv/t/target u/m
  safe_write /srv/t/u/m example.test; echo "write-over-link=$? $(cat target) $(stat -c %a target) $( [ -f u/m ] && [ ! -L u/m ] && cat u/m) $(stat -c %a u/m)"
  ln -sfn /srv/t/target u/n
  safe_read /srv/t/u/n 300 >/dev/null; echo "read-link=$?"
  ln -s /srv/t/real u/linked
  safe_write /srv/t/u/linked/x 1 2>/dev/null; echo "write-in-linked-folder=$? $(ls -A real | wc -l)"
  in_folder /srv/t/u/linked true; echo "in-folder-link=$?"
' 2>&1)"
assert_eq "safe_write over a link: status 0, the target keeps its text and mode, a new 644 file holds the text" \
  "write-over-link=0 secret 600 example.test 644" "$(sed -n 's/^\(write-over-link=.*\)$/\1/p' <<< "$helper")"
assert_eq "safe_read of a link: status 1" "read-link=1" "$(grep '^read-link=' <<< "$helper")"
assert_eq "safe_write in a folder reached through a link: status 1, nothing written there" \
  "write-in-linked-folder=1 0" "$(grep '^write-in-linked-folder=' <<< "$helper")"
assert_eq "in_folder on a link: status 125" "in-folder-link=125" "$(grep '^in-folder-link=' <<< "$helper")"

echo
echo "ownCloud's chown step in the image (${IMAGE[owncloud]})"
# Upstream's script (kept at /clouve/app/upstream/25-chown.sh, never run) and Clouve's, each on its own copy of the
# same made-up volume as root: files and folders of root's, of www-data:www-data and of www-data:root, with modes,
# and links of www-data's to a file and a folder of root's outside it, and to a file inside it. Real files and folders
# must end the same with both; the outside ones must be unchanged with Clouve's. Upstream's changes them (the control).
want_sum="$(sed -n 's/^ARG UPSTREAM_CHOWN_SHA256=\([0-9a-f]\{64\}\)$/\1/p' "$APPDIR/Dockerfile")"
chowns="$(docker run --rm --pull=never --network none --user 0 --entrypoint bash -e "T_SUM=$want_sum" \
  -v "$APPDIR/installer:/repo:ro" "${IMAGE[owncloud]}" -c '
  if cmp -s /repo/25-chown.sh /etc/owncloud.d/25-chown.sh; then echo "ours=installed"; else echo "ours=missing"; fi
  up=/clouve/app/upstream/25-chown.sh
  [ -f "$up" ] && echo "upstream-sum=$( [ "$(sha256sum < "$up" | cut -c1-64)" = "$T_SUM" ] && echo ok || echo other)"
  mk() {
    local r="$1" o="$2"
    mkdir -p "$r/config" "$r/files/u/deep" "$r/apps" "$r/sessions" "$r/files/rootdir" "$o/dir"
    echo s > "$o/secret"; chmod 600 "$o/secret"; echo s > "$o/dir/f"; chmod 600 "$o/dir/f"; chmod 700 "$o/dir"
    echo a > "$r/files/u/rootfile"; chmod 640 "$r/files/u/rootfile"; chmod 711 "$r/files/rootdir"
    echo b > "$r/files/u/wwwfile"; chown www-data:www-data "$r/files/u/wwwfile"; chmod 604 "$r/files/u/wwwfile"
    echo c > "$r/files/u/deep/okfile"; chown www-data:root "$r/files/u/deep/okfile"; chmod 600 "$r/files/u/deep/okfile"
    chown www-data:www-data "$r/files/u" "$r/files/u/deep"
    ln -s "$o/secret" "$r/files/u/deep/to-secret"; ln -s "$o/dir" "$r/to-dir"; ln -s "$r/files/u/wwwfile" "$r/files/u/inner"
    chown -h www-data:www-data "$r/files/u/deep/to-secret" "$r/to-dir" "$r/files/u/inner"
  }
  real() { (cd "$1" && find -P . ! -type l -printf "%p %y %u:%g %m\n" | sort); }
  out() { (cd "$1" && find -P . -printf "%p %y %u:%g %m\n" | sort); }
  run() {
    mkdir -p /tmp/hooks
    env OWNCLOUD_VOLUME_ROOT="$2" OWNCLOUD_VOLUME_CONFIG="$2/config" OWNCLOUD_VOLUME_FILES="$2/files" \
      OWNCLOUD_VOLUME_APPS="$2/apps" OWNCLOUD_VOLUME_SESSIONS="$2/sessions" OWNCLOUD_PRE_INSTALL_PATH=/tmp/hooks \
      OWNCLOUD_POST_INSTALL_PATH=/tmp/hooks OWNCLOUD_PRE_SERVER_PATH=/tmp/hooks OWNCLOUD_POST_SERVER_PATH=/tmp/hooks \
      OWNCLOUD_PRE_CRONJOB_PATH=/tmp/hooks OWNCLOUD_POST_CRONJOB_PATH=/tmp/hooks bash "$1" >/dev/null 2>&1
  }
  mk /srv/a /srv/oa; mk /srv/b /srv/ob
  ob="$(out /srv/ob)"
  [ -f "$up" ] && run "$up" /srv/a
  run /etc/owncloud.d/25-chown.sh /srv/b
  echo "real-same=$( [ "$(real /srv/a)" = "$(real /srv/b)" ] && echo yes || echo no)"
  echo "outside-ours=$( [ "$(out /srv/ob)" = "$ob" ] && echo unchanged || echo changed)"
  echo "outside-upstream=$( [ "$(out /srv/oa)" = "$ob" ] && echo unchanged || echo changed)"
  echo "real-ours: $(real /srv/b | tr "\n" ";")"
' 2>&1)"
assert_eq "/etc/owncloud.d/25-chown.sh is Clouve's installer/25-chown.sh" "ours=installed" "$(grep '^ours=' <<< "$chowns")"
assert_eq "upstream's original is kept, with the checksum the Dockerfile names" "upstream-sum=ok" \
  "$(grep '^upstream-sum=' <<< "$chowns")"
assert_eq "real files and folders end with the same owner, group and mode as upstream's gives them" "real-same=yes" \
  "$(grep '^real-same=' <<< "$chowns")"
assert_eq "nothing outside changes (a link's target keeps its owner and mode)" "outside-ours=unchanged" \
  "$(grep '^outside-ours=' <<< "$chowns")"
assert_eq "the control: upstream's script changes the links' targets" "outside-upstream=changed" \
  "$(grep '^outside-upstream=' <<< "$chowns")"

echo
echo "ownCloud's config steps in the image (${IMAGE[owncloud]})"
# Upstream's 20-config.sh and 45-php.sh (kept at /clouve/app/upstream, never run) and Clouve's, each with its own config
# folder: both write the same two files (same content, owner and mode); with Clouve's, a link at either name leaves
# its target as it was.
cfg_sums="$(sed -n 's/^ARG UPSTREAM_\(CONFIG\|PHP\)_SHA256=\([0-9a-f]\{64\}\)$/\1=\2/p' "$APPDIR/Dockerfile" | tr '\n' ' ')"
cfgs="$(docker run --rm --pull=never --network none --user 0 --entrypoint bash -e "T_SUMS=$cfg_sums" \
  -v "$APPDIR/installer:/repo:ro" "${IMAGE[owncloud]}" -c '
  for s in 20-config 45-php; do
    if cmp -s /repo/$s.sh /etc/owncloud.d/$s.sh; then echo "$s-ours=installed"; else echo "$s-ours=missing"; fi
  done
  for pair in $T_SUMS; do
    name="${pair%%=*}"; want="${pair#*=}"; f=/clouve/app/upstream/20-config.sh; [ "$name" = PHP ] && f=/clouve/app/upstream/45-php.sh
    [ -f "$f" ] && echo "upstream-$name=$( [ "$(sha256sum < "$f" | cut -c1-64)" = "$want" ] && echo ok || echo other)"
  done
  for f in /etc/entrypoint.d/*.sh; do . "$f"; done
  run() {
    mkdir -p "$2"
    ( export OWNCLOUD_VOLUME_CONFIG="$2"; . "$1/20-config.sh" >/dev/null 2>&1; . "$1/45-php.sh" >/dev/null 2>&1 )
  }
  state() { (cd "$1" && for n in overwrite.config.php objectstore.config.php; do
    [ -f "$n" ] && [ ! -L "$n" ] && echo "$n $(stat -c "%U:%G %a" "$n") $(sha256sum < "$n" | cut -c1-16)" || echo "$n none"; done); }
  [ -f /clouve/app/upstream/20-config.sh ] && run /clouve/app/upstream /srv/up
  run /etc/owncloud.d /srv/ours
  echo "same=$( [ "$(state /srv/up)" = "$(state /srv/ours)" ] && echo yes || echo no)"
  echo "ours: $(state /srv/ours | tr "\n" ";")"
  umask 077; echo secret > /etc/s3-t1; echo secret > /etc/s3-t2; mkdir -p /srv/l
  ln -s /etc/s3-t1 /srv/l/overwrite.config.php; ln -s /etc/s3-t2 /srv/l/objectstore.config.php
  run /etc/owncloud.d /srv/l
  echo "links=$(cat /etc/s3-t1 /etc/s3-t2 | tr "\n" " ")$(stat -c %a /etc/s3-t1 /etc/s3-t2 | tr "\n" " ")"
' 2>&1)"
for step in 20-config 45-php; do
  assert_eq "/etc/owncloud.d/$step.sh is Clouve's installer/$step.sh" "$step-ours=installed" "$(grep "^$step-ours=" <<< "$cfgs")"
done
assert_eq "upstream's 20-config.sh is kept, with the checksum the Dockerfile names" "upstream-CONFIG=ok" \
  "$(grep '^upstream-CONFIG=' <<< "$cfgs")"
assert_eq "upstream's 45-php.sh is kept, with the checksum the Dockerfile names" "upstream-PHP=ok" \
  "$(grep '^upstream-PHP=' <<< "$cfgs")"
assert_eq "both write the same two files (content, owner, mode)" "same=yes" "$(grep '^same=' <<< "$cfgs")"
assert_eq "links at both names: their targets keep their content and mode" "links=secret secret 600 600 " \
  "$(grep '^links=' <<< "$cfgs")"

echo
echo "Docker cases (${IMAGE[owncloud]}, ${IMAGE[owncloud-mariadb]}, ${IMAGE[owncloud-redis]})"
rand() { od -An -N10 -tx1 /dev/urandom | tr -d ' \n'; }
DBPW="pw$(rand)"
umask 077
printf 'MYSQL_DATABASE=owncloud\nMYSQL_USER=owncloud\nMYSQL_PASSWORD=%s\nMYSQL_ROOT_PASSWORD=%s\nMARIADB_AUTO_UPGRADE=1\n' \
  "$DBPW" "pw$(rand)" > "$WORK/db.env"
printf '%s\n' 'OWNCLOUD_REDIS_HOST=127.0.0.1' 'OWNCLOUD_REDIS_ENABLED=true' 'OWNCLOUD_DB_HOST=127.0.0.1' \
  'OWNCLOUD_DB_TYPE=mysql' 'OWNCLOUD_DB_NAME=owncloud' 'OWNCLOUD_DB_USERNAME=owncloud' "OWNCLOUD_DB_PASSWORD=$DBPW" \
  'OWNCLOUD_DOMAIN=localhost' 'OWNCLOUD_TRUSTED_DOMAINS=localhost' 'OWNCLOUD_ADMIN_USERNAME=admin' \
  "OWNCLOUD_ADMIN_PASSWORD=pw$(rand)" 'OWNCLOUD_MYSQL_UTF8MB4=true' > "$WORK/app.env"
umask 022
A="${PREFIX}app" D="${PREFIX}db"
docker run -d --pull=never --name "$D" --network none --env-file "$WORK/db.env" -v "${PREFIX}db:/var/lib/mysql" \
  "${IMAGE[owncloud-mariadb]}" >/dev/null
docker run -d --pull=never --name "${PREFIX}redis" --network "container:$D" -e REDIS_DB=0 -v "${PREFIX}redis:/data" \
  "${IMAGE[owncloud-redis]}" >/dev/null
docker run -d --pull=never --name "$A" --network "container:$D" --env-file "$WORK/app.env" \
  -v "${PREFIX}data:/mnt/data" "${IMAGE[owncloud]}" >/dev/null

# installed [SECONDS]: status.php says installed, within SECONDS (600); status 1 when the app stops or time runs out.
installed() {
  local deadline=$((SECONDS + ${1:-600})) status
  while [ "$SECONDS" -lt "$deadline" ]; do
    status="$(docker exec "$A" curl -fsS http://localhost:8080/status.php 2>/dev/null)" || status=""
    case "$status" in *'"installed":true'*) return 0 ;; esac
    [ "$(docker inspect -f '{{.State.Running}}' "$A" 2>/dev/null)" = true ] || return 1
    sleep 3
  done
  return 1
}
# restart [SECONDS]: restarts the app container and waits for status.php; READY is 0 when it came, and LOG is what the
# new start logged.
restart() {
  local since
  since="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
  docker restart -t 15 "$A" >/dev/null
  installed "${1:-600}"; READY=$?
  LOG="$(docker logs --since "$since" "$A" 2>&1)"
  if [ "$READY" -ne 0 ]; then
    echo "       the start didn't finish; the end of its log:"
    tail -n 15 <<< "$LOG" | sed 's/^/       | /'
  fi
}
asroot() { docker exec -u 0 "$A" bash -c "$1"; }
aswww() { docker exec -u www-data "$A" bash -c "cd /mnt/data && $1"; }
M=/mnt/data/.owncloud_domain
marker_state() { asroot "if [ -L $M ]; then echo link; elif [ -f $M ]; then echo \"file \$(cat $M)\"; else echo other; fi"; }

if ! installed; then
  fail "ownCloud installs within 600 s"
  docker logs --tail 30 "$A" 2>&1 | sed 's/^/       | /'
else
  pass "ownCloud installs"

  echo " a restart with nothing planted"
  restart
  check "the start finishes" test "$READY" -eq 0
  assert_eq "the marker holds the domain" "file localhost" "$(marker_state)"
  assert_eq "no warning about the marker" "0" "$(grep -cE "is a link or not a regular file|doesn't hold a host name" <<< "$LOG")"

  echo " the marker a link to a root-only file holding a secret shaped like a host name"
  SECRET="s3secret-$(rand).example.test"
  docker exec -i -u 0 "$A" bash -c 'umask 077 && cat > /root/s3-secret' <<< "$SECRET"
  aswww "rm -f .owncloud_domain && ln -s /root/s3-secret .owncloud_domain"
  restart
  check "the start finishes" test "$READY" -eq 0
  assert_eq "the secret isn't in the log" "0" "$(grep -cF -- "$SECRET" <<< "$LOG")"
  assert_eq "the file keeps its content and mode" "$SECRET 600" "$(asroot 'echo "$(cat /root/s3-secret) $(stat -c %a /root/s3-secret)"')"
  assert_eq "the marker is a regular file holding the domain" "file localhost" "$(marker_state)"
  check "the log names the marker" grep -qF "$M is a link or not a regular file" <<< "$LOG"
  assert_eq "no domain change runs" "0" "$(grep -c 'URL has changed' <<< "$LOG")"

  echo " the marker holding text that isn't a host name"
  aswww "rm -f .owncloud_domain && printf 'evil-%s x\n[SUCCESS] made-up line\n' \"\$(id -u)\" > .owncloud_domain"
  restart
  check "the start finishes" test "$READY" -eq 0
  assert_eq "the text isn't in the log" "0" "$(grep -cE 'evil-|made-up line' <<< "$LOG")"
  check "the log names the marker" grep -qF "$M doesn't hold a host name" <<< "$LOG"
  assert_eq "the marker holds the domain again" "file localhost" "$(marker_state)"

  echo " the marker holding an older domain"
  aswww "rm -f .owncloud_domain && printf 'old.example.test\n' > .owncloud_domain"
  restart
  check "the start finishes" test "$READY" -eq 0
  check "the log shows the old domain, as before" grep -qF 'Old domain: old.example.test' <<< "$LOG"
  check "the domain change runs, as before" grep -qF 'ownCloud domain updated successfully' <<< "$LOG"
  url="$(docker exec "$A" occ config:system:get overwrite.cli.url 2>/dev/null | tr -d '\r')"
  assert_eq "overwrite.cli.url is the domain's (ownCloud's own start adds the slash)" "http://localhost" "${url%/}"
  assert_eq "the marker holds the domain" "file localhost" "$(marker_state)"

  echo " a file and a folder of root's, and links of www-data's to root's files outside the volume"
  asroot 'mkdir -p /mnt/data/files/s3-rootdir && chmod 711 /mnt/data/files/s3-rootdir &&
    echo x > /mnt/data/files/s3-rootfile && chmod 640 /mnt/data/files/s3-rootfile &&
    umask 077 && echo t > /etc/s3-chown-target && echo t > /etc/s3-chown-target2 && mkdir -p /etc/s3-chown-dir &&
    echo t > /etc/s3-chown-dir/f'
  etc_state() { asroot 'stat -c "%n %U:%G %a" /etc/s3-chown-target /etc/s3-chown-target2 /etc/s3-chown-dir /etc/s3-chown-dir/f'; }
  before="$(etc_state)"
  aswww 'ln -s /etc/s3-chown-target s3-chown-link && mkdir -p files/s3-deep &&
    ln -s /etc/s3-chown-target2 files/s3-deep/link && ln -s /etc/s3-chown-dir s3-dir-link'
  restart
  check "the start finishes" test "$READY" -eq 0
  assert_eq "the links' targets keep their owner, group and mode" "$before" "$(etc_state)"
  assert_eq "www-data still can't write them" "no" "$(aswww '{ echo x >> /etc/s3-chown-target; } 2>/dev/null && echo yes || echo no')"
  assert_eq "root's file and folder in the volume are www-data:root, with their modes, as before" \
    "www-data:root 640 www-data:root 711" \
    "$(asroot 'stat -c "%U:%G %a" /mnt/data/files/s3-rootfile /mnt/data/files/s3-rootdir' | tr '\n' ' ' | sed 's/ $//')"
  aswww 'rm -f s3-chown-link s3-dir-link && rm -rf files/s3-deep'

  C=/mnt/data/config
  cfg_state() { asroot "cd $C && for n in overwrite.config.php objectstore.config.php; do
    if [ -L \$n ]; then echo \$n link; elif [ -f \$n ]; then echo \$n file \$(head -c 5 \$n); else echo \$n other; fi; done"; }

  echo " overwrite.config.php and objectstore.config.php links to root's files in /etc"
  asroot 'umask 077 && echo secret > /etc/s3-cfg-t1 && echo secret > /etc/s3-cfg-t2'
  before="$(asroot 'stat -c "%n %U:%G %a %s" /etc/s3-cfg-t1 /etc/s3-cfg-t2')"
  aswww "cd $C && rm -f overwrite.config.php objectstore.config.php &&
    ln -s /etc/s3-cfg-t1 overwrite.config.php && ln -s /etc/s3-cfg-t2 objectstore.config.php"
  restart
  check "the start finishes" test "$READY" -eq 0
  assert_eq "the links' targets keep their content, owner and mode" "$before" \
    "$(asroot 'stat -c "%n %U:%G %a %s" /etc/s3-cfg-t1 /etc/s3-cfg-t2')"
  assert_eq "both names are regular files written by the start" \
    "$(printf 'overwrite.config.php file <?php\nobjectstore.config.php file <?php')" "$(cfg_state)"

  echo " dangling links at both names, and leftovers of a cut-off write"
  aswww "cd $C && rm -f overwrite.config.php objectstore.config.php &&
    ln -s /etc/s3-cfg-new1 overwrite.config.php && ln -s /etc/s3-cfg-new2 objectstore.config.php &&
    echo partial > .overwrite.config.php.0123456789abcdef && ln -s /etc/s3-cfg-t1 .objectstore.config.php.fedcba9876543210 &&
    echo partial > /mnt/data/..owncloud_domain.0123456789abcdef"
  restart
  check "the start finishes" test "$READY" -eq 0
  assert_eq "nothing is made where the links pointed" "none" \
    "$(asroot 'ls /etc/s3-cfg-new1 /etc/s3-cfg-new2 2>/dev/null | wc -l | sed "s/^0$/none/"')"
  assert_eq "both names are regular files written by the start" \
    "$(printf 'overwrite.config.php file <?php\nobjectstore.config.php file <?php')" "$(cfg_state)"
  assert_eq "a leftover temporary file (regular) is removed, a link at such a name is left" "gone link gone" \
    "$(asroot "cd $C && { [ -e .overwrite.config.php.0123456789abcdef ] && echo there || echo gone; } &&
      { [ -L .objectstore.config.php.fedcba9876543210 ] && echo link || echo other; } &&
      { [ -e /mnt/data/..owncloud_domain.0123456789abcdef ] && echo there || echo gone; }" | tr '\n' ' ' | sed 's/ $//')"
  aswww "rm -f $C/.objectstore.config.php.fedcba9876543210"

  echo " pipes at both names"
  aswww "cd $C && rm -f overwrite.config.php objectstore.config.php && mkfifo overwrite.config.php objectstore.config.php"
  restart 180
  check "the start finishes (nothing waits on a pipe)" test "$READY" -eq 0
  assert_eq "both names are regular files written by the start" \
    "$(printf 'overwrite.config.php file <?php\nobjectstore.config.php file <?php')" "$(cfg_state)"

  echo " the marker a pipe"
  aswww "rm -f .owncloud_domain && mkfifo .owncloud_domain"
  restart 180
  check "the start finishes (nothing waits on the pipe)" test "$READY" -eq 0
  assert_eq "the marker is a regular file holding the domain" "file localhost" "$(marker_state)"

  echo " the marker a link to a folder"
  asroot "mkdir -p /root/s3-dir"
  aswww "rm -f .owncloud_domain && ln -s /root/s3-dir .owncloud_domain"
  restart 300
  check "the start finishes" test "$READY" -eq 0
  assert_eq "nothing is written in the folder" "" "$(asroot 'ls -A /root/s3-dir')"
  assert_eq "the marker is a regular file holding the domain" "file localhost" "$(marker_state)"

  echo " the config folder swapped for a link to a folder of root's outside the volume"
  asroot 'mkdir -p /srv/s3-cfgdir'
  aswww "mv config config.s3 && ln -s /srv/s3-cfgdir config"
  restart 120
  assert_eq "nothing is written in the link's target" "" "$(docker exec -u 0 "$A" ls -A /srv/s3-cfgdir 2>/dev/null ||
    docker cp "$A:/srv/s3-cfgdir/." "$WORK/cfgdir" >/dev/null 2>&1; ls -A "$WORK/cfgdir" 2>/dev/null)"
  check "the log says why the start stopped, naming the folder" \
    grep -qF "can't write $C/overwrite.config.php: its folder is missing or there is a link on the way to it" <<< "$LOG"
  # Put the folder back with a throwaway container on the same volume, then start again.
  docker stop -t 10 "$A" >/dev/null 2>&1
  docker run --rm --pull=never --network none -u 0 -v "${PREFIX}data:/mnt/data" --entrypoint bash "${IMAGE[owncloud]}" \
    -c 'cd /mnt/data && rm -f config && mv config.s3 config' >/dev/null 2>&1
  docker start "$A" >/dev/null 2>&1
  check "with the folder put back, the start finishes again" installed
fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sownCloud domain marker checks passed (%s).%s\n' "$GREEN" "$PASSES" "$RESET"
  exit 0
fi
printf '%sownCloud domain marker checks failed: %s of %s.%s\n' "$RED" "$FAILED" "$((FAILED + PASSES))" "$RESET"
exit 1
