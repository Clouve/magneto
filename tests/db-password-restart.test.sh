#!/bin/bash

# ============================================================================
# A rotated database password reaches the app at its next start (release 4.5.6, #109)
# ============================================================================
# strato's rotate_db_password changes the app user's password in the database, puts the new one in the deployment's
# Secret and restarts every container that reads it. That works only where the app takes the password from its
# environment at start (or at each request), and not from a file its first install wrote. LimeSurvey, SuiteCRM, the
# Customer Kit and Gibbon's and Moodle's update-config.sh have tests of their own for this; this one covers WordPress,
# Odoo, Nextcloud and ownCloud, with the images as they are:
#   - the database and the app start from the app's clv-docker-compose.yml, on volumes of their own, and the app
#     installs and serves;
#   - the user's password is changed in the database (as its administrator, the way the action's Job ends up) and the
#     app container is made again on the same volumes, as a restart after the Secret changed does;
#   - with the OLD password in its environment the app can't serve: the check can fail;
#   - with the NEW one it serves again, without a database error: it picked the password up at start;
#   - the old password is refused by the database.
# Every container runs with no network: the database has --network none and the others share its network
# namespace, so no Docker bridge is used. It never prints a password, and none is on a command line: the settings go
# in mode 600 env files, a password reaches docker exec by its variable's name alone, and grep reads it from a file.
#
# The images are r.clv.zone/e2eorg/<name>:latest unless --image NAME=REF names another; they must be on this machine
# (./build.sh <app> first). Needs Docker and python3 with PyYAML. About 10 minutes for the four apps.
#
# Usage: bash tests/db-password-restart.test.sh [--image NAME=REF]... [wordpress|odoo|nextcloud|owncloud]...
# ============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
FAILED=0
pass() { printf '  %bPASS%b %s\n' "$GREEN" "$NC" "$1"; }
fail() { printf '  %bFAIL%b %s\n' "$RED" "$NC" "$1"; FAILED=1; }

declare -A IMAGE=()
APPS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE["${2%%=*}"]="${2#*=}"; shift 2 ;;
    wordpress | odoo | nextcloud | owncloud) APPS+=("$1"); shift ;;
    *) echo "Usage: bash tests/db-password-restart.test.sh [--image NAME=REF]... [wordpress|odoo|nextcloud|owncloud]..." >&2; exit 2 ;;
  esac
done
[ ${#APPS[@]} -gt 0 ] || APPS=(wordpress odoo nextcloud owncloud)
command -v docker > /dev/null && docker info > /dev/null 2>&1 || { echo "This test needs Docker." >&2; exit 2; }
python3 -c 'import yaml' 2> /dev/null || { echo "This test needs python3 with PyYAML." >&2; exit 2; }

PREFIX="dbpw-restart-$$-"
WORK="$(mktemp -d)"
chmod 700 "$WORK"
cleanup() {
  local ids
  ids="$(docker ps -aq --filter "name=^$PREFIX")"
  [ -z "$ids" ] || docker rm -f -v $ids > /dev/null 2>&1
  ids="$(docker volume ls -q --filter "name=^$PREFIX")"
  [ -z "$ids" ] || docker volume rm $ids > /dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# plan APP: from the manifest, one line per service: "<service> <purpose> <port> <volume>:<path>,..." and a file
# $WORK/APP.<service>.env (mode 600) with its settings. Secrets get made-up values (the database password is
# $WORK/APP.pw); a containerReference is 127.0.0.1 (WordPress's database host 127.0.0.1:3306); the app's own address
# is http://localhost and its host localhost.
plan() {
  python3 -I - "$REPO_DIR/apps/$1/clv-docker-compose.yml" "$WORK/$1" << 'PY'
import os, secrets, sys
import yaml
manifest, out = sys.argv[1:3]
doc = yaml.safe_load(open(manifest))
fills = {"{org.name}": "Test Org", "{user.firstName}": "Test", "{user.lastName}": "User", "{user.userEmail}": "admin@example.test"}
made = {}
def secret(key):
    made.setdefault(key, "pw" + secrets.token_hex(12))
    return made[key]
db_key = None
for name, svc in doc["services"].items():
    meta = svc.get("x-clouve-metadata") or {}
    if name == "magneto-agent" or meta.get("purpose") != "Database":
        continue
    env, types = svc.get("environment") or {}, svc.get("x-clouve-environment-types") or {}
    db_key = next(str(env[v]) for v in ("MYSQL_PASSWORD", "MARIADB_PASSWORD", "POSTGRES_PASSWORD") if v in env)
for name, svc in doc["services"].items():
    if name == "magneto-agent":
        continue
    meta = svc.get("x-clouve-metadata") or {}
    env, types = svc.get("environment") or {}, svc.get("x-clouve-environment-types") or {}
    lines = []
    for var, value in env.items():
        value, kind = str(value), types.get(var, "static")
        if kind in ("secret", "applicationPassword"): value = secret(value)
        elif kind == "containerReference": value = "127.0.0.1:3306" if var == "WORDPRESS_DB_HOST" else "127.0.0.1"
        elif kind == "applicationUrl": value = "http://localhost"
        elif kind == "applicationHost": value = "localhost"
        elif kind == "applicationUsername": value = "admin@example.test" if "EMAIL" in var else "clvadmin"
        else:
            for k, v in fills.items(): value = value.replace(k, v)
        lines.append("%s=%s" % (var, value))
    fd = os.open("%s.%s.env" % (out, name), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, ("\n".join(lines) + "\n").encode()); os.close(fd)
    port = str((svc.get("ports") or ["80:80"])[0]).split(":")[-1]
    vols = ",".join(str(v) for v in (svc.get("volumes") or []))
    print(name, meta.get("purpose") or "-", port, vols or "-")
fd = os.open(out + ".pw", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, secret(db_key).encode()); os.close(fd)
PY
}

# run_service APP SERVICE PURPOSE VOLUMES [ENVFILE]: starts the service's container (the database with no network,
# the others in its network namespace).
run_service() {
  local app="$1" svc="$2" purpose="$3" vols="$4" env="${5:-$WORK/$1.$2.env}" net v
  local -a mounts=()
  if [ "$vols" != - ]; then
    IFS=, read -r -a v <<< "$vols"
    for one in "${v[@]}"; do mounts+=(-v "$PREFIX$app-${one%%:*}:${one#*:}"); done
  fi
  [ "$purpose" = Database ] && net=none || net="container:$PREFIX$app-db"
  local name="$PREFIX$app-$svc"
  [ "$purpose" = Database ] && name="$PREFIX$app-db"
  docker run -d --pull=never --name "$name" --network "$net" --env-file "$env" "${mounts[@]}" \
    "${IMAGE[$svc]:-r.clv.zone/e2eorg/$svc:latest}" > /dev/null
}

# answer APP PORT PATH MARK: the app's answer to GET PATH as "<http code> <db-error|clean> <marked|unmarked>" (MARK is
# text the app's real page has, such as its sign-in form's field), asked from inside its container with
# Host: localhost (curl, python3 or php, whichever the image has).
answer() {
  docker exec -e T_PORT="$2" -e T_PATH="$3" -e T_MARK="$4" "$PREFIX$1-app" sh -c '
    if command -v curl > /dev/null; then
      code="$(curl -s -m 30 -o /tmp/clv-answer -w "%{http_code}" -H "Host: localhost" "http://127.0.0.1:$T_PORT$T_PATH")"
    elif command -v python3 > /dev/null; then
      code="$(python3 -c "
import os, urllib.request, urllib.error
req = urllib.request.Request(\"http://127.0.0.1:%s%s\" % (os.environ[\"T_PORT\"], os.environ[\"T_PATH\"]), headers={\"Host\": \"localhost\"})
try:
    r = urllib.request.urlopen(req, timeout=30); body, code = r.read(), r.status
except urllib.error.HTTPError as e:
    body, code = e.read(), e.code
open(\"/tmp/clv-answer\", \"wb\").write(body); print(code)" 2> /dev/null)"
    else
      code="$(php -r "\$c = stream_context_create([\"http\" => [\"header\" => \"Host: localhost\", \"ignore_errors\" => true, \"timeout\" => 30]]);
        \$b = @file_get_contents(\"http://127.0.0.1:\" . getenv(\"T_PORT\") . getenv(\"T_PATH\"), false, \$c);
        file_put_contents(\"/tmp/clv-answer\", (string) \$b); preg_match(\"#\\S+ (\\d{3})#\", \$http_response_header[0] ?? \"\", \$m); echo \$m[1] ?? 0;")"
    fi
    if grep -qiE "error establishing a database connection|database connection failed|could not connect to (the )?database|SQLSTATE|OperationalError|password authentication failed|Access denied for user|Internal Server Error" /tmp/clv-answer 2> /dev/null; then
      state=db-error; else state=clean; fi
    grep -qF -- "$T_MARK" /tmp/clv-answer 2> /dev/null && mark=marked || mark=unmarked
    echo "${code:-0} $state $mark"' 2> /dev/null
}
# serves APP PORT PATH SECONDS: until the app's real page answers 200, without a database error (a redirect, or a page
# that says no database could be chosen, doesn't count)
serves() {
  local deadline=$((SECONDS + $4)) a
  while [ "$SECONDS" -lt "$deadline" ]; do
    a="$(answer "$1" "$2" "$3" "${MARK_OF[$1]}")"
    case "$a" in "200 clean marked") return 0 ;; esac
    sleep 5
  done
  LAST_ANSWER="${a:-no answer}"
  return 1
}

# refuses APP PORT PATH SECONDS: the app never serves its real page: true when it answers with a database error or a
# redirect away from its page, when its container stops, or when SECONDS (as long as a good start gets) pass without
# its page; false as soon as it serves the page.
refuses() {
  local deadline=$((SECONDS + $4)) a
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$PREFIX$1-app" 2> /dev/null)" != true ]; then
      LAST_ANSWER="its container stopped"; return 0
    fi
    a="$(answer "$1" "$2" "$3" "${MARK_OF[$1]}")"
    case "$a" in
      "200 clean marked") LAST_ANSWER="$a"; return 1 ;;
      *" db-error "*) LAST_ANSWER="$a"; return 0 ;;
      3[0-9][0-9]\ clean\ unmarked) LAST_ANSWER="$a, a redirect away from its page"; return 0 ;;
    esac
    sleep 5
  done
  LAST_ANSWER="no page in $4 s (last: ${a:-no answer})"
  return 0
}

# db_set APP USER NEWPW: the database's administrator gives USER the new password (on stdin, never argv).
db_set() {
  if [ "$1" = odoo ]; then
    printf "ALTER ROLE \"%s\" PASSWORD '%s';\n" "$2" "$3" | docker exec -i "$PREFIX$1-db" psql -q -U "$2" -d postgres > /dev/null 2>&1
  else
    local root
    root="$(sed -n 's/^MYSQL_ROOT_PASSWORD=//p' "$WORK/$1.$DB_SVC.env")"
    printf "ALTER USER '%s'@'%%' IDENTIFIED BY '%s';\n" "$2" "$3" \
      | MYSQL_PWD="$root" docker exec -i -e MYSQL_PWD "$PREFIX$1-db" sh -c 'c="$(command -v mariadb || command -v mysql)"; "$c" -u root' > /dev/null 2>&1
  fi
}
# db_signs_in APP USER PW: whether USER signs in to the database over TCP with PW.
db_signs_in() {
  if [ "$1" = odoo ]; then
    PGPASSWORD="$3" docker exec -e PGPASSWORD "$PREFIX$1-db" psql -h 127.0.0.1 -U "$2" -d postgres -tAc 'SELECT 1' > /dev/null 2>&1
  else
    MYSQL_PWD="$3" docker exec -e MYSQL_PWD "$PREFIX$1-db" sh -c 'c="$(command -v mariadb || command -v mysql)"; "$c" -h 127.0.0.1 --protocol=tcp -u "$0" -e "SELECT 1"' "$2" > /dev/null 2>&1
  fi
}

declare -A PATH_OF=([wordpress]=/ [odoo]=/web/login [nextcloud]=/login [owncloud]=/login)
declare -A MARK_OF=([wordpress]=wp- [odoo]='name="login"' [nextcloud]=body-login [owncloud]='name="user"')

for app in "${APPS[@]}"; do
  echo "$app"
  lines="$(plan "$app")" || { fail "$app: the manifest can be read"; continue; }
  APP_SVC="$(awk '$2 != "Database" && $2 != "Cache" {print $1; exit}' <<< "$lines")"
  DB_SVC="$(awk '$2 == "Database" {print $1; exit}' <<< "$lines")"
  port="$(awk -v s="$APP_SVC" '$1 == s {print $3}' <<< "$lines")"
  missing=""
  while read -r svc _ _ _; do
    docker image inspect "${IMAGE[$svc]:-r.clv.zone/e2eorg/$svc:latest}" > /dev/null 2>&1 || missing="$missing $svc"
  done <<< "$lines"
  [ -z "$missing" ] || { fail "$app: the images are on this machine (missing:$missing; ./build.sh $app, or --image)"; continue; }

  read -r _ purpose _ vols <<< "$(awk -v s="$DB_SVC" '$1 == s' <<< "$lines")"
  run_service "$app" "$DB_SVC" Database "$vols"
  if [ "$app" = odoo ]; then
    # PostgreSQL's image trusts every connection over the loopback address. On a cluster the app reaches the database
    # through its Service, where the image's "host all all all scram-sha-256" line asks for the password; here the app
    # shares the database's loopback, so the loopback lines (the replication ones too) ask for it, or no password would
    # ever be checked.
    hba=""
    for _ in $(seq 60); do
      hba="$(docker exec "$PREFIX$app-db" sh -c 'psql -U "$POSTGRES_USER" -d postgres -tAc "SHOW hba_file"' 2> /dev/null)" && [ -n "$hba" ] && break
      sleep 2
    done
    if [ -n "$hba" ] && docker exec -e HBA="$hba" "$PREFIX$app-db" sh -c \
        'sed -i -E "s#^(host[[:space:]]+[a-z]+[[:space:]]+all[[:space:]]+(127\.0\.0\.1/32|::1/128)[[:space:]]+)trust#\1scram-sha-256#" "$HBA" &&
         ! grep -qE "^host[[:space:]].*trust" "$HBA" && psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT pg_reload_conf()" > /dev/null'; then
      pass "$app: the database asks for the password on every TCP connection, as on a cluster"
    else
      fail "$app: the database asks for the password on every TCP connection, as on a cluster"; continue
    fi
  fi
  while read -r svc purpose _ vols; do
    [ "$svc" = "$DB_SVC" ] || [ "$svc" = "$APP_SVC" ] || run_service "$app" "$svc" "$purpose" "$vols"
  done <<< "$lines"
  # The app's container is always named <app>-app, whatever its service is called.
  read -r _ purpose _ app_vols <<< "$(awk -v s="$APP_SVC" '$1 == s' <<< "$lines")"
  start_app() { # start_app ENVFILE
    docker rm -f "$PREFIX$app-app" > /dev/null 2>&1
    local -a mounts=() v
    if [ "$app_vols" != - ]; then IFS=, read -r -a v <<< "$app_vols"; for one in "${v[@]}"; do mounts+=(-v "$PREFIX$app-${one%%:*}:${one#*:}"); done; fi
    docker run -d --pull=never --name "$PREFIX$app-app" --network "container:$PREFIX$app-db" --env-file "$1" "${mounts[@]}" \
      "${IMAGE[$APP_SVC]:-r.clv.zone/e2eorg/$APP_SVC:latest}" > /dev/null
  }
  start_app "$WORK/$app.$APP_SVC.env"
  if serves "$app" "$port" "${PATH_OF[$app]}" 900; then
    pass "$app: installs and serves ${PATH_OF[$app]}"
  else
    fail "$app: installs and serves ${PATH_OF[$app]} (last answer: $LAST_ANSWER)"
    docker logs --tail 10 "$PREFIX$app-app" 2>&1 | grep -viE 'password|secret|token' | sed 's/^/       | /'
    # shellcheck disable=SC2046  # one id per word
    docker rm -f -v $(docker ps -aq --filter "name=^$PREFIX$app-") > /dev/null 2>&1
    continue
  fi

  old="$(cat "$WORK/$app.pw")"
  user="$(sed -n -E 's/^(MYSQL_USER|POSTGRES_USER)=//p' "$WORK/$app.$DB_SVC.env" | head -n 1)"
  new="R$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  if db_set "$app" "$user" "$new" && db_signs_in "$app" "$user" "$new"; then
    pass "$app: the database user has a new password"
  else
    fail "$app: the database user has a new password"; continue
  fi
  db_signs_in "$app" "$user" "$old" && fail "$app: the database refuses the old password" || pass "$app: the database refuses the old password"

  # A start with the old password in the environment: the app can't serve (so the next check can fail). It gets as
  # long as the good start below, unless it shows a database error, redirects away from its page or stops first.
  start_app "$WORK/$app.$APP_SVC.env"
  if refuses "$app" "$port" "${PATH_OF[$app]}" 600; then
    pass "$app: with the old password it can't reach its database ($LAST_ANSWER)"
  else
    fail "$app: with the old password it can't reach its database (it served: the check below proves nothing)"
  fi

  # The restart after the rotation: every variable that held the old password now holds the new one.
  OLD_PW="$old" NEW_PW="$new" python3 -I -c '
import os, sys
old, new = os.environ["OLD_PW"], os.environ["NEW_PW"]
src, dst = sys.argv[1:3]
lines = [l.split("=", 1) for l in open(src).read().splitlines() if "=" in l]
fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, ("\n".join("%s=%s" % (k, new if v == old else v) for k, v in lines) + "\n").encode()); os.close(fd)' \
    "$WORK/$app.$APP_SVC.env" "$WORK/$app.rotated.env"
  start_app "$WORK/$app.rotated.env"
  if serves "$app" "$port" "${PATH_OF[$app]}" 600; then
    pass "$app: restarted with the new password, it serves ${PATH_OF[$app]} without a database error"
  else
    fail "$app: restarted with the new password, it serves ${PATH_OF[$app]} without a database error (last answer: $LAST_ANSWER)"
  fi
  leaked=0
  docker logs "$PREFIX$app-app" 2>&1 | grep -qF -f <(printf '%s\n' "$new") && leaked=1
  [ "$leaked" -eq 0 ] && pass "$app: the app's log doesn't hold the new password" || fail "$app: the app's log holds the new password"
  old=""; new=""
  # shellcheck disable=SC2046  # one id per word
  docker rm -f -v $(docker ps -aq --filter "name=^$PREFIX$app-") > /dev/null 2>&1
done

echo
if [ "$FAILED" -eq 0 ]; then printf '%bDatabase password restart tests passed.%b\n' "$GREEN" "$NC"; exit 0
else printf '%bDatabase password restart tests FAILED.%b\n' "$RED" "$NC"; exit 1; fi
