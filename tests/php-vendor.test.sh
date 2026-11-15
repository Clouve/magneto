#!/bin/bash

# ============================================================================
# Gibbon's and Moodle's PHP libraries: the fixed versions, in the image and on
# a site that was installed before them
# ============================================================================
# Trivy found critical advisories in libraries the two apps ship in vendor/:
# Gibbon 30.0.01's twig/twig 3.11.3 and phpoffice/phpspreadsheet 1.30.0, and
# Moodle 5.3's mtdowling/jmespath.php 2.8.0. The images update those
# packages, inside the apps' own version ranges, and refresh-vendor.sh puts
# them on sites that already run the same app version
# (tests/vendor-refresh.test.sh has its cases). For each app this test checks
# that:
#   - the image's package list has the fixed versions, and no package other
#     than the ones named below differs from the old image's;
#   - the image records upstream's id and file list (the old image's
#     vendor/) for refresh-vendor.sh;
#   - the old images install a site with no network (the app in the
#     database's network namespace, settings from clv-docker-compose.yml, on
#     named volumes), then the new images start on the same volumes: the log
#     has one "[clouve-vendor] vendor/ now has the image's libraries" line,
#     the site's vendor/ has the fixed versions, the marker records the app's
#     version, and a restart doesn't copy again;
#   - the site still works: Gibbon signs its admin in, serves the dashboard,
#     Manage Users and a Students report (Twig pages) with no Twig or PHP
#     error, exports that report as an XLSX file (PhpSpreadsheet) and never
#     serves its clouve/ state folder; Moodle serves its front page (not an
#     upgrade page), signs its admin in and serves the dashboard (/my/), and
#     JmesPath\search() runs under the site's own config.php and autoloader.
#
# --image NAME=REF uses an image that is already built. NAME is gibbon,
# gibbon-mysql, moodle or moodle-mysql (the new images, built from this
# checkout otherwise), or the same with -old (the images before the update,
# built from OLD_REF otherwise). Naming apps limits the run. Containers and
# volumes are named phpvendor-t-<pid>-*, so runs don't touch each other. The
# admin's password reaches the containers in an env file (mode 600) and curl
# from a file. Needs Docker, git and python3 with PyYAML.
#
# Usage: bash tests/php-vendor.test.sh [--image NAME=REF]... [--old-ref GIT_REF] [gibbon|moodle]...
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="phpvendor-t-$$-"
READY_SECONDS=900
# The last commit whose Gibbon and Moodle images ship upstream's vendor/.
OLD_REF=0a9c049

declare -A PKG_DIR=([gibbon]=/clouve/gibbon/gibbon-30.0.01 [moodle]=/clouve/moodle/moodle-5.3)
declare -A EXPECT=(
  [gibbon]="twig/twig=v3.30.0 phpoffice/phpspreadsheet=1.30.7"
  [moodle]="mtdowling/jmespath.php=2.9.2"
)
# Packages that may differ from the old image: the updated ones and the dependencies Composer had to move with them.
# twig 3.30 needs PHP 8.1 and no longer the PHP 8.1 polyfill, so Composer removes symfony/polyfill-php81 (PHP 8.3 has
# those functions built in).
declare -A MAY_CHANGE=(
  [gibbon]="twig/twig phpoffice/phpspreadsheet symfony/polyfill-php81"
  [moodle]="mtdowling/jmespath.php"
)
declare -A APP_VERSION=([gibbon]=30.0.01 [moodle]=2026100500)
declare -A DB_OF=([gibbon]=gibbon-mysql [moodle]=moodle-mysql)
declare -A VOLUMES=(
  [gibbon]="gibbondata:/var/www/html"
  [gibbon-mysql]="dbdata:/var/lib/mysql"
  [moodle]="moodle-www-data:/var/www/html moodle-data:/var/moodledata"
  [moodle-mysql]="moodle-db-data:/var/lib/mysql"
)
declare -A IMAGE=()

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

APPS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      [[ "${2:-}" =~ ^(gibbon|gibbon-mysql|moodle|moodle-mysql)(-old)?=.+ ]] || usage
      IMAGE[${2%%=*}]="${2#*=}"
      shift
      ;;
    --old-ref) [ -n "${2:-}" ] || usage; OLD_REF="$2"; shift ;;
    gibbon|moodle) APPS+=("$1") ;;
    *) usage ;;
  esac
  shift
done
[ "${#APPS[@]}" -gt 0 ] || APPS=(gibbon moodle)

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

WORK="$(mktemp -d)"
chmod 700 "$WORK"
BUILT=()
# remove_test_things: this run's containers and volumes (each named after its app), not another run's.
remove_test_things() {
  local name app
  for app in "${APPS[@]}"; do
    while IFS= read -r name; do
      case "$name" in "$PREFIX$app" | "$PREFIX$app"-*) docker rm -f -v "$name" >/dev/null 2>&1 ;; esac
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
    while IFS= read -r name; do
      case "$name" in "$PREFIX$app"-*) docker volume rm -f "$name" >/dev/null 2>&1 ;; esac
    done < <(docker volume ls --format '{{.Name}}' 2>/dev/null)
  done
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
remove_test_things

# context NAME: the build folder of an image (NAME without -old).
context() {
  case "$1" in
    gibbon|moodle) echo "apps/$1/image" ;;
    gibbon-mysql) echo apps/gibbon/image/mysql ;;
    moodle-mysql) echo apps/moodle/image/mysql ;;
  esac
}

# image_for NAME: builds NAME (from this checkout, or from OLD_REF for a -old name) unless --image gave it.
image_for() {
  local name="$1" base="${1%-old}" dir log
  [ -n "${IMAGE[$name]:-}" ] && { docker image inspect "${IMAGE[$name]}" >/dev/null 2>&1; return; }
  IMAGE[$name]="clouve-test/$name:phpvendor-test"
  if [ "$name" = "$base" ]; then
    dir="$REPO_DIR/$(context "$base")"
  else
    dir="$WORK/old-$base"
    mkdir -p "$dir"
    git -C "$REPO_DIR" archive "$OLD_REF" "$(context "$base")" | tar -x -C "$dir" --strip-components="$(context "$base" | tr '/' '\n' | wc -l)" ||
      return 1
  fi
  if log="$(docker build -t "${IMAGE[$name]}" "$dir" 2>&1)"; then
    BUILT+=("${IMAGE[$name]}")
  else
    printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
    return 1
  fi
}

# packages IMAGE PATH: "name=version" lines from PATH/vendor/composer/installed.json in IMAGE, sorted.
# shellcheck disable=SC2016  # PHP code
read_packages='$d = json_decode(file_get_contents($argv[1]), true); $p = $d["packages"] ?? $d;
  foreach ($p as $x) echo $x["name"], "=", $x["version"], "\n";'
packages() {
  docker run --rm --pull=never --network none --entrypoint php "$1" -n -r "$read_packages" -- \
    "$2/vendor/composer/installed.json" 2>/dev/null | sort
}

# env_files APP: $WORK/APP.app.env and $WORK/APP.db.env (mode 600) from the app's clv-docker-compose.yml, as
# tests/app-ops-password.test.sh writes them; prints "user=<admin user>" and "passvar=<VAR>".
env_files() {
  python3 -I - "$REPO_DIR/apps/$1/clv-docker-compose.yml" "$WORK/$1" <<'PY'
import os, secrets, sys
import yaml
manifest, out = sys.argv[1:3]
doc = yaml.safe_load(open(manifest))
fills = {"{org.name}": "Test Org", "{user.firstName}": "Test", "{user.lastName}": "User",
         "{user.userEmail}": "admin@example.test"}
made = {}
def secret(original, admin=False):
    if original not in made:
        made[original] = ("Aa1!-" if admin else "pw-") + secrets.token_hex(8)
    return made[original]
app = db = None
for name, svc in doc["services"].items():
    purpose = ((svc.get("x-clouve-metadata") or {}).get("purpose") or "")
    if purpose == "Database": db = svc
    elif app is None: app = svc
for svc, suffix in ((app, "app"), (db, "db")):
    types = svc.get("x-clouve-environment-types") or {}
    lines = []
    for var, value in (svc.get("environment") or {}).items():
        value, kind = str(value), types.get(var, "static")
        if kind == "secret": value = secret(value)
        elif kind == "applicationPassword":
            value = secret(value, admin=True); print("passvar=%s" % var)
        elif kind == "containerReference": value = "127.0.0.1"
        elif kind == "applicationUrl": value = "http://localhost"
        else:
            for k, v in fills.items(): value = value.replace(k, v)
        if kind == "applicationUsername" and "@" not in value: print("user=%s" % value)
        lines.append("%s=%s" % (var, value))
    path = "%s.%s.env" % (out, suffix)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, ("\n".join(lines) + "\n").encode()); os.close(fd)
PY
}

# volume_args APP NAME: -v options for NAME's volumes, named under the app's prefix.
volume_args() {
  local v
  for v in ${VOLUMES[$2]}; do printf -- '-v\n%s%s-%s\n' "$PREFIX" "$1" "$v"; done
}

# start APP SUFFIX: the database and the app from IMAGE[db SUFFIX] and IMAGE[app SUFFIX] on the app's volumes, then
# waits until Apache is PID 1 and answers. SUFFIX is "" or "-old".
start() {
  local app="$1" sfx="$2" db="${DB_OF[$1]}" D="${PREFIX}$1-db" A="${PREFIX}$1" deadline
  local -a dbv appv
  mapfile -t dbv < <(volume_args "$app" "$db")
  mapfile -t appv < <(volume_args "$app" "$app")
  docker run -d --pull=never --name "$D" --network none --env-file "$WORK/$app.db.env" "${dbv[@]}" \
    "${IMAGE[$db$sfx]}" >/dev/null || return 1
  docker run -d --pull=never --name "$A" --network "container:$D" --env-file "$WORK/$app.app.env" "${appv[@]}" \
    "${IMAGE[$app$sfx]}" >/dev/null || return 1
  wait_ready "$A"
}
wait_ready() {
  local deadline=$((SECONDS + READY_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(docker exec "$1" cat /proc/1/comm 2>/dev/null)" = apache2 ] &&
       docker exec "$1" curl -s -o /dev/null http://localhost/ 2>/dev/null; then
      return 0
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" != true ]; then break; fi
    sleep 3
  done
  docker logs --tail 20 "$1" 2>&1 | sed 's/^/       | /'
  return 1
}
stop() { docker rm -f "${PREFIX}$1" "${PREFIX}$1-db" >/dev/null 2>&1; }

vendor_line="[clouve-vendor] vendor/ now has the image's libraries"

for app in "${APPS[@]}"; do
  echo
  echo "$app"
  db="${DB_OF[$app]}"
  ok=true
  for name in "$app" "$db" "$app-old" "$db-old"; do
    image_for "$name" || { fail "the image $name builds or is on this machine"; ok=false; }
  done
  $ok || continue

  # What the image holds.
  new_list="$(packages "${IMAGE[$app]}" "${PKG_DIR[$app]}")"
  old_list="$(packages "${IMAGE[$app-old]}" "${PKG_DIR[$app]}")"
  for want in ${EXPECT[$app]}; do
    assert_eq "the image has ${want%%=*} ${want#*=}" "$want" "$(grep -x -- "${want%%=*}=.*" <<< "$new_list")"
  done
  changed="$(diff <(echo "$old_list") <(echo "$new_list") | sed -n 's/^[<>] \([^=]*\)=.*/\1/p' | sort -u)"
  extra="$(comm -23 <(echo "$changed") <(tr ' ' '\n' <<< "${MAY_CHANGE[$app]}" | sort -u) | paste -sd' ')"
  assert_eq "no other package differs from the old image's" "" "$extra"
  # shellcheck disable=SC2016  # the command runs in the container
  ids="$(docker run -i --rm --pull=never --network none --entrypoint bash "${IMAGE[$app-old]}" -c \
    'cat > /tmp/r.sh && bash /tmp/r.sh --id "$1/vendor"' _ "${PKG_DIR[$app]}" \
    < "$REPO_DIR/apps/$app/image/installer/refresh-vendor.sh")"
  recorded="$(docker run --rm --pull=never --network none --entrypoint cat "${IMAGE[$app]}" "/clouve/$app/vendor-upstream.id" 2>&1)"
  if [[ "$ids" =~ ^[0-9a-f]{64}$ ]] && [ "$recorded" = "$ids" ]; then
    pass "the image records upstream's vendor id (the old image's)"
  else
    fail "the image records upstream's vendor id (the old image's)"
    printf '       old image: %q\n       recorded:  %q\n' "$ids" "$recorded"
  fi
  # shellcheck disable=SC2016  # the command runs in the container
  old_sums="$(docker run -i --rm --pull=never --network none --entrypoint bash "${IMAGE[$app-old]}" -c \
    'cat > /tmp/r.sh && bash /tmp/r.sh --sums "$1/vendor"' _ "${PKG_DIR[$app]}" \
    < "$REPO_DIR/apps/$app/image/installer/refresh-vendor.sh" | sha256sum)"
  new_sums="$(docker run --rm --pull=never --network none --entrypoint cat "${IMAGE[$app]}" "/clouve/$app/vendor-upstream.sums" \
    2>/dev/null | sha256sum)"
  assert_eq "the image records upstream's file list (the old image's)" "$old_sums" "$new_sums"

  # A site the old image installed, then the new image on the same volumes.
  info="$(env_files "$app")" || { fail "the settings can be read from the manifest"; continue; }
  admin_user="$(sed -n 's/^user=//p' <<< "$info" | head -n 1)"
  admin_var="$(sed -n 's/^passvar=//p' <<< "$info" | head -n 1)"
  (umask 077; printf 'T_U=%s\nT_P=%s\n' "$admin_user" "$(sed -n "s/^$admin_var=//p" "$WORK/$app.app.env")" \
    > "$WORK/$app.admin.env")
  if ! start "$app" -old; then fail "the old image installs $app"; stop "$app"; remove_test_things; continue; fi
  pass "the old image installs $app"
  stop "$app"
  if ! start "$app" ""; then fail "the new image starts on the old site's volumes"; stop "$app"; remove_test_things; continue; fi
  pass "the new image starts on the old site's volumes"
  A="${PREFIX}$app"
  assert_eq "the log says once that vendor/ was refreshed" 1 "$(docker logs "$A" 2>&1 | grep -cxF -- "$vendor_line")"
  site_list="$(docker exec "$A" php -n -r "$read_packages" -- /var/www/html/vendor/composer/installed.json | sort)"
  for want in ${EXPECT[$app]}; do
    assert_eq "the site's vendor/ has ${want%%=*} ${want#*=}" "$want" "$(grep -x -- "${want%%=*}=.*" <<< "$site_list")"
  done
  assert_eq "the site's package list is the image's" "$new_list" "$site_list"
  assert_eq "the marker records the app's version" "${APP_VERSION[$app]}" \
    "$(docker exec "$A" cut -d' ' -f1 /var/www/html/clouve/installed/vendor-id 2>/dev/null)"
  docker restart "$A" >/dev/null
  if wait_ready "$A"; then pass "a restart starts"; else fail "a restart starts"; fi
  assert_eq "a restart doesn't copy vendor/ again" 1 "$(docker logs "$A" 2>&1 | grep -cxF -- "$vendor_line")"

  # The site still works.
  if [ "$app" = gibbon ]; then
    # shellcheck disable=SC2016  # the script runs in the container
    out="$(docker exec --env-file "$WORK/$app.admin.env" "$A" bash -c '
      j=$(mktemp); h=$(mktemp); pf=$(mktemp)
      printf "%s" "$T_P" > "$pf"
      curl -s -o /dev/null -c "$j" -b "$j" http://localhost/
      loc=$(curl -s -o /dev/null -D - -c "$j" -b "$j" --data-urlencode "username=$T_U" --data-urlencode "password@$pf" \
        http://localhost/login.php | tr -d "\r" | sed -n "s/^[Ll]ocation: //p")
      rm -f "$pf"
      case "$loc" in *loginReturn*|"") echo "signin=no"; exit ;; esac
      echo "signin=yes"
      for q in "" "/modules/User%20Admin/user_manage.php" "/modules/Students/report_transport_student.php"; do
        url="http://localhost/index.php"; [ -n "$q" ] && url="$url?q=$q"
        code=$(curl -s -o "$h" -w "%{http_code}" -c "$j" -b "$j" "$url")
        bad=$(grep -c -E "Twig\\\\Error|Fatal error|Uncaught|Warning</b>" "$h")
        out=$(grep -c -E "gibbon|Gibbon" "$h")
        echo "page ${q:-/} code=$code errors=$bad gibbon=$([ "$out" -gt 0 ] && echo yes || echo no)"
      done
      x=$(mktemp)
      ct=$(curl -s -o "$x" -w "%{content_type}" -c "$j" -b "$j" \
        "http://localhost/export.php?q=/modules/Students/report_transport_student.php&format=export")
      echo "export type=$ct zip=$(head -c 2 "$x")"
      echo "state code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/clouve/installed/vendor-id)"
      rm -f "$j" "$h" "$x"' 2>&1)"
    assert_eq "Gibbon signs its admin in" "signin=yes" "$(sed -n 1p <<< "$out")"
    for q in / /modules/User%20Admin/user_manage.php /modules/Students/report_transport_student.php; do
      assert_eq "Gibbon serves $q with no Twig or PHP error" "page $q code=200 errors=0 gibbon=yes" \
        "$(grep -F -- "page $q " <<< "$out")"
    done
    assert_eq "Gibbon never serves its clouve/ state folder" "state code=403" "$(grep '^state ' <<< "$out")"
    exp="$(grep '^export ' <<< "$out")"
    case "$exp" in
      *spreadsheetml*zip=PK) pass "Gibbon exports the report as an XLSX file" ;;
      *) fail "Gibbon exports the report as an XLSX file"; printf '       %s\n' "$exp" ;;
    esac
    if docker logs "$A" 2>&1 | grep -qE 'PHP (Fatal|Parse) error|Twig\\Error'; then
      fail "the container's log has no PHP fatal or Twig error"
    else
      pass "the container's log has no PHP fatal or Twig error"
    fi
  else
    front="$(docker exec "$A" curl -sL -o /dev/null -w '%{http_code} %{url_effective}' http://localhost/)"
    case "$front" in
      "200 "*/admin/*|"200 "*/upgrade*) fail "Moodle serves its front page, not an upgrade page"; printf '       %s\n' "$front" ;;
      "200 "*) pass "Moodle serves its front page, not an upgrade page" ;;
      *) fail "Moodle serves its front page, not an upgrade page"; printf '       %s\n' "$front" ;;
    esac
    # shellcheck disable=SC2016  # the script runs in the container
    out="$(docker exec --env-file "$WORK/$app.admin.env" "$A" bash -c '
      j=$(mktemp); h=$(mktemp); pf=$(mktemp)
      printf "%s" "$T_P" > "$pf"
      token=$(curl -s -c "$j" -b "$j" http://localhost/login/index.php | sed -n "s/.*name=\"logintoken\" value=\"\([^\"]*\)\".*/\1/p" | head -n 1)
      curl -s -o /dev/null -c "$j" -b "$j" --data-urlencode "username=$T_U" --data-urlencode "password@$pf" \
        --data-urlencode "logintoken=$token" http://localhost/login/index.php
      rm -f "$pf"
      res=$(curl -sL -o "$h" -w "%{http_code} %{url_effective}" -c "$j" -b "$j" http://localhost/my/)
      bad=$(grep -c -E "Fatal error|Uncaught|Warning</b>" "$h")
      dash=$(grep -c "id=\"page-my-index\"" "$h")
      echo "my $res errors=$bad dashboard=$([ "$dash" -gt 0 ] && echo yes || echo no)"
      rm -f "$j" "$h"' 2>&1)"
    case "$out" in
      "my 200 "*/my/*" errors=0 dashboard=yes") pass "Moodle signs its admin in and serves the dashboard (/my/)" ;;
      *) fail "Moodle signs its admin in and serves the dashboard (/my/)"; printf '       %s\n' "$out" ;;
    esac
    # shellcheck disable=SC2016  # PHP code
    assert_eq "JmesPath\\search() runs under the site's autoloader" "7" "$(docker exec "$A" php -r '
      define("CLI_SCRIPT", true); require "/var/www/html/config.php";
      echo json_encode(JmesPath\search("a.b", ["a" => ["b" => 7]]));' 2>/dev/null | tail -n 1)"
  fi
  stop "$app"
  remove_test_things
done

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sPHP library checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sPHP library checks failed.%s\n' "$RED" "$RESET"
exit 1
