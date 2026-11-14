#!/bin/bash

# ============================================================================
# The ownCloud images: pinned bases, a clean install, and an upgrade
# ============================================================================
# The ownCloud image is built FROM owncloud/server at the version the listing
# names (appVersion in clv-docker-compose.yml), never an untagged :latest, and
# its database image FROM mariadb:12.3. This test checks that:
#   - the image's ownCloud is the listing's appVersion (version.php), and the
#     database image's server is MariaDB 12.3;
#   - mariadb, redis and ownCloud, started from the three images with no
#     network (one network namespace, so 127.0.0.1 reaches each), install
#     ownCloud: status.php says installed, at that version, the manifest's
#     health check command (/usr/bin/healthcheck) passes, and
#     occ integrity:check-core finds nothing wrong. Its signature covers the
#     web updater (/var/www/owncloud/updater) too, so the image keeps it:
#     without it every admin would see a failed check. A control then takes a
#     core file away and expects the check to report it, so a check that
#     stopped running can't pass;
#   - an older site moves: ownCloud 10.16.0 on MariaDB 11.4 (images built from
#     this folder with those two bases; the listing ran 10.16.0 before it was
#     pinned) installs and stores a file, then the current images start on the
#     same volumes: ownCloud migrates to the new version (status.php says no
#     database upgrade is pending and the site isn't in maintenance), MariaDB
#     upgrades the data, the integrity check is clean, and the file is still
#     there.
#
# --image NAME=REF uses an image that is already built (NAME is owncloud,
# owncloud-mariadb, owncloud-redis, owncloud-old or owncloud-mariadb-old);
# otherwise the test builds it and removes it at the end. Containers and
# volumes are named octest-<pid>-*, so runs don't touch each other. Passwords
# reach the containers in env files (mode 600), never on a command line.
# Needs Docker and python3 with PyYAML.
#
# Usage: bash tests/owncloud-image.test.sh [--image NAME=REF]...
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="octest-$$-"
READY_SECONDS=600
OLD_OWNCLOUD=10.16.0
OLD_MARIADB=11.4
MARIADB_SERIES=12.3

declare -A CONTEXT=(
  [owncloud]="$REPO_DIR/apps/owncloud/image"
  [owncloud-mariadb]="$REPO_DIR/apps/owncloud/image/mariadb"
  [owncloud-redis]="$REPO_DIR/apps/owncloud/image/redis"
  [owncloud-old]="$REPO_DIR/apps/owncloud/image"
  [owncloud-mariadb-old]="$REPO_DIR/apps/owncloud/image/mariadb"
)
declare -A IMAGE=()

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      [[ "${2:-}" == ?*=?* ]] || usage
      name="${2%%=*}"
      [ -n "${CONTEXT[$name]+set}" ] || usage
      IMAGE[$name]="${2#*=}"
      shift
      ;;
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

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi

OWNCLOUD_VERSION="$(python3 -I -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
print(doc["services"]["owncloud"]["x-clouve-bundle-metadata"]["appVersion"])' "$REPO_DIR/apps/owncloud/clv-docker-compose.yml")" ||
  { echo "Can't read appVersion from apps/owncloud/clv-docker-compose.yml." >&2; exit 2; }

WORK="$(mktemp -d)"
chmod 700 "$WORK"
BUILT=()
remove_test_things() {
  local name
  while IFS= read -r name; do
    case "$name" in "$PREFIX"*) docker rm -f -v "$name" >/dev/null 2>&1 ;; esac
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
  while IFS= read -r name; do
    case "$name" in "$PREFIX"*) docker volume rm -f "$name" >/dev/null 2>&1 ;; esac
  done < <(docker volume ls --format '{{.Name}}' 2>/dev/null)
}
# shellcheck disable=SC2329  # the EXIT trap runs it
cleanup() {
  local image
  remove_test_things
  for image in "${BUILT[@]}"; do docker rmi -f "$image" >/dev/null 2>&1; done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# image_for NAME: builds NAME unless --image gave it. The -old images are this folder's Dockerfiles with their FROM
# line set to the older base.
image_for() {
  local name="$1" dir="${CONTEXT[$1]}" log
  if [ -n "${IMAGE[$name]:-}" ]; then
    docker image inspect "${IMAGE[$name]}" >/dev/null 2>&1 || { fail "the image ${IMAGE[$name]} is on this machine"; return 1; }
    return 0
  fi
  IMAGE[$name]="clouve-test/$name:owncloud-test-$$"
  case "$name" in
    owncloud-old)
      cp -r "$dir" "$WORK/old-app"
      sed -i "s#^FROM owncloud/server:.*#FROM owncloud/server:$OLD_OWNCLOUD#" "$WORK/old-app/Dockerfile"
      dir="$WORK/old-app"
      ;;
    owncloud-mariadb-old)
      mkdir -p "$WORK/old-db"
      printf 'FROM mariadb:%s\n' "$OLD_MARIADB" > "$WORK/old-db/Dockerfile"
      dir="$WORK/old-db"
      ;;
  esac
  if log="$(docker build -t "${IMAGE[$name]}" "$dir" 2>&1)"; then
    BUILT+=("${IMAGE[$name]}")
  else
    fail "$name builds"
    printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
    return 1
  fi
}
for name in owncloud owncloud-mariadb owncloud-redis owncloud-old owncloud-mariadb-old; do
  image_for "$name" || exit 1
done

# The settings, in env files only this user can read.
rand() { head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9'; }
DB_PASSWORD="$(rand)"
ADMIN_PASSWORD="$(rand)"
umask 077
printf 'MYSQL_DATABASE=owncloud\nMYSQL_USER=owncloud\nMYSQL_PASSWORD=%s\nMYSQL_ROOT_PASSWORD=%s\nMARIADB_AUTO_UPGRADE=1\n' \
  "$DB_PASSWORD" "$(rand)" > "$WORK/db.env"
printf '%s\n' 'OWNCLOUD_REDIS_HOST=127.0.0.1' 'OWNCLOUD_REDIS_ENABLED=true' 'OWNCLOUD_DB_HOST=127.0.0.1' \
  'OWNCLOUD_DB_TYPE=mysql' 'OWNCLOUD_DB_NAME=owncloud' 'OWNCLOUD_DB_USERNAME=owncloud' "OWNCLOUD_DB_PASSWORD=$DB_PASSWORD" \
  'OWNCLOUD_DOMAIN=localhost' 'OWNCLOUD_TRUSTED_DOMAINS=localhost' 'OWNCLOUD_ADMIN_USERNAME=admin' \
  "OWNCLOUD_ADMIN_PASSWORD=$ADMIN_PASSWORD" 'OWNCLOUD_MYSQL_UTF8MB4=true' > "$WORK/app.env"
printf 'T_USER=admin\nT_PASSWORD=%s\n' "$ADMIN_PASSWORD" > "$WORK/admin.env"
umask 022

# start SET DB APP [VOLUMES]: the three containers for SET (db, redis, app); with VOLUMES, on named volumes of SET.
start() {
  local set="$1" db="$2" app="$3" vols="${4:-}"
  local -a dbv=() rv=() av=()
  if [ -n "$vols" ]; then
    dbv=(-v "${PREFIX}${set}-db:/var/lib/mysql")
    rv=(-v "${PREFIX}${set}-redis:/data")
    av=(-v "${PREFIX}${set}-data:/mnt/data")
  fi
  docker run -d --pull=never --name "${PREFIX}${set}-db" --network none --env-file "$WORK/db.env" "${dbv[@]}" \
    "${IMAGE[$db]}" >/dev/null || return 1
  docker run -d --pull=never --name "${PREFIX}${set}-redis" --network "container:${PREFIX}${set}-db" -e REDIS_DB=0 \
    "${rv[@]}" "${IMAGE[owncloud-redis]}" >/dev/null || return 1
  docker run -d --pull=never --name "${PREFIX}${set}-app" --network "container:${PREFIX}${set}-db" \
    --env-file "$WORK/app.env" "${av[@]}" "${IMAGE[$app]}" >/dev/null || return 1
}
stop() { docker rm -f "${PREFIX}$1-app" "${PREFIX}$1-redis" "${PREFIX}$1-db" >/dev/null 2>&1; }

# wait_installed SET: status.php says installed, within READY_SECONDS. Sets STATUS.
wait_installed() {
  local deadline=$((SECONDS + READY_SECONDS))
  STATUS=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    STATUS="$(docker exec "${PREFIX}$1-app" curl -fsS http://localhost:8080/status.php 2>/dev/null)" || STATUS=""
    case "$STATUS" in *'"installed":true'*) return 0 ;; esac
    if [ "$(docker inspect -f '{{.State.Running}}' "${PREFIX}$1-app" 2>/dev/null)" != true ]; then break; fi
    sleep 5
  done
  docker logs --tail 30 "${PREFIX}$1-app" 2>&1 | sed 's/^/       | /'
  return 1
}
version_of() { sed -n 's/.*"versionstring":"\([^"]*\)".*/\1/p' <<< "$1"; }
# settled STATUS: "settled" when status.php says the database needs no upgrade and the site isn't in maintenance
# (versionstring is the code's version; these two say the database moved with it).
settled() {
  case "$1" in *'"maintenance":false'*) ;; *) echo "maintenance: not false"; return ;; esac
  case "$1" in *'"needsDbUpgrade":false'*) echo settled ;; *) echo "needsDbUpgrade: not false" ;; esac
}

# integrity SET: "clean", or what the check reported.
integrity() {
  local out rc
  out="$(docker exec "${PREFIX}$1-app" occ integrity:check-core 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && ! grep -qE 'INVALID_HASH|FILE_MISSING|EXTRA_FILE|EXCEPTION' <<< "$out"; then
    echo clean
  else
    printf 'exit %s\n%s\n' "$rc" "$out" | head -n 12
  fi
}

# webdav SET put|get NAME [CONTENT]: ownCloud's WebDAV as the admin; the password reaches curl on stdin.
# shellcheck disable=SC2016  # the script runs in the container
webdav() {
  local set="$1" op="$2" name="$3" content="${4:-}"
  docker exec -i --env-file "$WORK/admin.env" -e "T_OP=$op" -e "T_NAME=$name" "${PREFIX}$set-app" sh -c '
    if [ "$T_OP" = put ]; then
      printf "user = \"%s:%s\"\n" "$T_USER" "$T_PASSWORD" > /tmp/curl.cfg
      cat > /tmp/upload
      curl -s -o /dev/null -w "%{http_code}" -K /tmp/curl.cfg -T /tmp/upload "http://localhost:8080/remote.php/webdav/$T_NAME"
    else
      printf "user = \"%s:%s\"\n" "$T_USER" "$T_PASSWORD" > /tmp/curl.cfg
      curl -s -K /tmp/curl.cfg "http://localhost:8080/remote.php/webdav/$T_NAME"
    fi
    rm -f /tmp/curl.cfg /tmp/upload' <<< "$content"
}

echo "What the images hold"
in_image() { docker run --rm --pull=never --network none --entrypoint sh "$1" -c "$2" 2>&1; }
assert_eq "its ownCloud is the listing's appVersion, $OWNCLOUD_VERSION" "$OWNCLOUD_VERSION" \
  "$(in_image "${IMAGE[owncloud]}" "sed -n \"s/^\\\$OC_VersionString = '\\(.*\\)';/\\1/p\" /var/www/owncloud/version.php")"
db_version="$(in_image "${IMAGE[owncloud-mariadb]}" 'mariadbd --version' | sed -n 's/.*Ver \([0-9.]*\)-MariaDB.*/\1/p')"
assert_eq "its database server is MariaDB $MARIADB_SERIES" "$MARIADB_SERIES" "${db_version%.*}"

echo "A new install with no network"
remove_test_things
if start new owncloud-mariadb owncloud && wait_installed new; then
  pass "status.php says installed"
  assert_eq "status.php names $OWNCLOUD_VERSION" "$OWNCLOUD_VERSION" "$(version_of "$STATUS")"
  assert_eq "no database upgrade pending, no maintenance" settled "$(settled "$STATUS")"
  if docker exec "${PREFIX}new-app" /usr/bin/healthcheck >/dev/null 2>&1; then
    pass "the manifest's health check passes"
  else
    fail "the manifest's health check passes"
  fi
  result="$(integrity new)"
  assert_eq "occ integrity:check-core finds nothing wrong" "clean" "$(head -n 1 <<< "$result")"
  [ "$result" = clean ] || printf '%s\n' "$result" | sed 's/^/       /'
  # The control: a core file taken away has to show.
  docker exec "${PREFIX}new-app" mv /var/www/owncloud/robots.txt /tmp/robots.txt
  control="$(integrity new)"
  if grep -q 'FILE_MISSING' <<< "$control" && grep -q 'robots.txt' <<< "$control"; then
    pass "the check reports a core file taken away (so it does run)"
  else
    fail "the check reports a core file taken away (so it does run)"
  fi
  docker exec "${PREFIX}new-app" mv /tmp/robots.txt /var/www/owncloud/robots.txt
else
  fail "status.php says installed within ${READY_SECONDS}s"
fi
stop new

echo "A site ownCloud $OLD_OWNCLOUD installed on MariaDB $OLD_MARIADB, then the current images"
NOTE="clouve upgrade test $(rand)"
if start up owncloud-mariadb-old owncloud-old volumes && wait_installed up; then
  assert_eq "the old site runs $OLD_OWNCLOUD" "$OLD_OWNCLOUD" "$(version_of "$STATUS")"
  assert_eq "a file is stored through WebDAV" "201" "$(webdav up put note.txt "$NOTE")"
  stop up
  if start up owncloud-mariadb owncloud volumes && wait_installed up; then
    pass "the current images start on the old site's volumes"
    assert_eq "ownCloud is now $OWNCLOUD_VERSION" "$OWNCLOUD_VERSION" "$(version_of "$STATUS")"
    assert_eq "the database moved too: no upgrade pending, no maintenance" settled "$(settled "$STATUS")"
    db_now="$(docker exec "${PREFIX}up-db" mariadbd --version 2>/dev/null | sed -n 's/.*Ver \([0-9.]*\)-MariaDB.*/\1/p')"
    assert_eq "the data is served by MariaDB $MARIADB_SERIES" "$MARIADB_SERIES" "${db_now%.*}"
    result="$(integrity up)"
    assert_eq "occ integrity:check-core finds nothing wrong" "clean" "$(head -n 1 <<< "$result")"
    [ "$result" = clean ] || printf '%s\n' "$result" | sed 's/^/       /'
    assert_eq "the file stored before is still there" "$NOTE" "$(webdav up get note.txt)"
  else
    fail "the current images start on the old site's volumes"
  fi
else
  fail "the old images install a site"
fi
stop up

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sownCloud image checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sownCloud image checks failed.%s\n' "$RED" "$RESET"
exit 1
