#!/bin/bash

# ============================================================================
# CLOUVE_OPS_PASSWORD stays out of Apache in the WordPress, Gibbon, Moodle,
# LimeSurvey and SuiteCRM app containers
# ============================================================================
# Each app image starts its clouve-ops sshd in the background (which applies
# CLOUVE_OPS_PASSWORD to the clouve-ops user, who has passwordless sudo) and
# then becomes Apache. mod_php's getenv() reads Apache's environment, so any
# PHP code (a plugin, a theme, a code-execution bug) could read the password
# if Apache kept it. The entrypoints unset it once the sshd start has its own
# copy.
#
# For each app the test installs it for real: its database image with no
# network (--network none) and the app image in the database's network
# namespace, with the settings of its clv-docker-compose.yml (placeholders
# filled in with test values, each secret a random value, hosts 127.0.0.1)
# and CLOUVE_OPS_PASSWORD set on the app. Once Apache is PID 1 and answers:
#   - a PHP file served by Apache (run by www-data) finds no
#     CLOUVE_OPS_PASSWORD through getenv(), $_SERVER or $_ENV;
#   - PID 1's environment (Apache, read as root) holds no such name;
#   - clouve-ops still signs in over SSH with the password;
#   - the container's log holds none of the passwords (M4);
#   - Moodle only: the admin's password, which the install passes to
#     install.php without a command line, signs in (M4).
#
# --image NAME=REF uses an image already built (NAME is wordpress,
# wordpress-mariadb, gibbon, gibbon-mysql, moodle, moodle-mysql, limesurvey,
# limesurvey-mariadb, suitecrm or suitecrm-mariadb); otherwise
# the test builds it and removes it at the end. Naming apps limits the run.
# Every container is named appops-t-*. Needs Docker and python3 with PyYAML.
#
# Usage: bash tests/app-ops-password.test.sh [--image NAME=REF]... [APP...]
#   APP  wordpress, gibbon, moodle, limesurvey or suitecrm (default: all)
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="appops-t-"
READY_SECONDS=600

ALL=(wordpress gibbon moodle limesurvey suitecrm)
declare -A DB_OF=([wordpress]=wordpress-mariadb [gibbon]=gibbon-mysql [moodle]=moodle-mysql
  [limesurvey]=limesurvey-mariadb [suitecrm]=suitecrm-mariadb)
# The port Apache listens on, where it isn't 80.
declare -A PORT=([limesurvey]=8080)
declare -A CONTEXT=(
  [wordpress]="$REPO_DIR/apps/wordpress/image" [wordpress-mariadb]="$REPO_DIR/apps/wordpress/image/mariadb"
  [gibbon]="$REPO_DIR/apps/gibbon/image" [gibbon-mysql]="$REPO_DIR/apps/gibbon/image/mysql"
  [moodle]="$REPO_DIR/apps/moodle/image" [moodle-mysql]="$REPO_DIR/apps/moodle/image/mysql"
  [limesurvey]="$REPO_DIR/apps/limesurvey/image" [limesurvey-mariadb]="$REPO_DIR/apps/limesurvey/image/mariadb"
  [suitecrm]="$REPO_DIR/apps/suitecrm/image" [suitecrm-mariadb]="$REPO_DIR/apps/suitecrm/image/mariadb"
)
declare -A IMAGE=()

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/(default: all)/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

APPS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      [[ "${2:-}" == ?*=?* ]] || usage
      name="${2%%=*}"
      [ -n "${CONTEXT[$name]+set}" ] || usage
      IMAGE[$name]="${2#*=}"
      shift
      ;;
    wordpress|gibbon|moodle|limesurvey|suitecrm) APPS+=("$1") ;;
    *) usage ;;
  esac
  shift
done
[ "${#APPS[@]}" -gt 0 ] || APPS=("${ALL[@]}")

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
remove_test_containers() {
  local name
  while IFS= read -r name; do
    case "$name" in "$PREFIX"*) docker rm -f -v "$name" >/dev/null 2>&1 ;; esac
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
}
# shellcheck disable=SC2329  # the EXIT trap runs it
cleanup() {
  local image
  remove_test_containers
  for image in "${BUILT[@]}"; do docker rmi -f "$image" >/dev/null 2>&1; done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
remove_test_containers

image_for() {
  local name="$1" log
  if [ -z "${IMAGE[$name]:-}" ]; then
    IMAGE[$name]="clouve-test/$name:appops-test"
    if log="$(docker build -t "${IMAGE[$name]}" "${CONTEXT[$name]}" 2>&1)"; then
      BUILT+=("${IMAGE[$name]}")
    else
      printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
      return 1
    fi
  fi
  docker image inspect "${IMAGE[$name]}" >/dev/null 2>&1
}

# env_files APP: writes $WORK/APP.app.env and $WORK/APP.db.env (mode 600) from the app's clv-docker-compose.yml, and
# $WORK/APP.secrets (one value per line: every password the deployment holds, for the log check). Prints the app's
# admin user name and password names as "user=<name>" and "passvar=<VAR>" lines.
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
        # Moodle's admin password has a quote, a double quote, a $ and a backslash: what its install builds from it
        # has to keep it whole. Other apps get letters and digits (Gibbon's form has its own password rules).
        tail = "-'q\"$\\" if admin and "moodle" in manifest else ""
        made[original] = ("Aa1!-" if admin else "pw-") + secrets.token_hex(8) + tail
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
        if kind in ("secret",): value = secret(value)
        elif kind == "applicationPassword":
            value = secret(value, admin=True); print("passvar=%s" % var)
        elif kind == "containerReference": value = "127.0.0.1:3306" if var.endswith("DB_HOST") and "WORDPRESS" in var else "127.0.0.1"
        elif kind == "applicationUrl": value = "http://localhost"
        else:
            for k, v in fills.items(): value = value.replace(k, v)
        if kind == "applicationUsername" and "@" not in value: print("user=%s" % value)
        if "\n" in value: sys.exit("a value with a line break can't go in an env file")
        lines.append("%s=%s" % (var, value))
    path = "%s.%s.env" % (out, suffix)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, ("\n".join(lines) + "\n").encode()); os.close(fd)
fd = os.open(out + ".secrets", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, ("\n".join(made.values()) + "\n").encode()); os.close(fd)
PY
}

rand() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }

for app in "${APPS[@]}"; do
  echo
  echo "$app"
  db="${DB_OF[$app]}"
  if ! image_for "$db" || ! image_for "$app"; then fail "the images build or are on this machine"; continue; fi
  info="$(env_files "$app")" || { fail "the settings can be read from the manifest"; continue; }
  admin_user="$(sed -n 's/^user=//p' <<< "$info" | head -n 1)"
  admin_var="$(sed -n 's/^passvar=//p' <<< "$info" | head -n 1)"
  ops_pw="$(rand)"
  printf '%s\n' "$ops_pw" >> "$WORK/$app.secrets"
  D="$PREFIX$app-db" A="$PREFIX$app"
  docker run -d --pull=never --name "$D" --network none --env-file "$WORK/$app.db.env" "${IMAGE[$db]}" >/dev/null
  docker run -d --pull=never --name "$A" --network "container:$D" --env-file "$WORK/$app.app.env" \
    -e "CLOUVE_OPS_PASSWORD=$ops_pw" "${IMAGE[$app]}" >/dev/null
  ready=false
  deadline=$((SECONDS + READY_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(docker exec "$A" cat /proc/1/comm 2>/dev/null)" = apache2 ] &&
       docker exec "$A" curl -s -o /dev/null "http://127.0.0.1:${PORT[$app]:-80}/" 2>/dev/null; then
      ready=true
      break
    fi
    sleep 3
  done
  if ! $ready; then
    fail "$app installs and Apache answers within ${READY_SECONDS} s"
    docker logs --tail 15 "$A" 2>&1 | sed 's/^/       | /'
    docker rm -f -v "$A" "$D" >/dev/null 2>&1
    continue
  fi
  pass "$app installs and Apache (PID 1) answers"

  # A PHP file in Apache's document root, run by an Apache worker.
  docroot="$(docker exec "$A" sh -c "grep -h -m1 '^[[:space:]]*DocumentRoot' /etc/apache2/sites-enabled/*.conf | awk '{print \$2}'")"
  # shellcheck disable=SC2016  # PHP code
  docker exec -i "$A" sh -c "cat > '$docroot/clv-ops-probe.php' && chmod 644 '$docroot/clv-ops-probe.php'" <<'PHP'
<?php
$n = 'CLOUVE_OPS_PASSWORD';
echo 'user=', function_exists('posix_geteuid') ? posix_getpwuid(posix_geteuid())['name'] : '?',
     ' getenv=', getenv($n) === false ? 'absent' : 'present',
     ' server=', isset($_SERVER[$n]) ? 'present' : 'absent',
     ' env=', isset($_ENV[$n]) ? 'present' : 'absent', "\n";
PHP
  probe="$(docker exec "$A" curl -s "http://127.0.0.1:${PORT[$app]:-80}/clv-ops-probe.php")"
  docker exec "$A" rm -f "$docroot/clv-ops-probe.php"
  assert_eq "PHP under Apache finds no CLOUVE_OPS_PASSWORD" "user=www-data getenv=absent server=absent env=absent" "$probe"
  names="$(docker exec "$A" sh -c 'tr "\0" "\n" < /proc/1/environ | cut -d= -f1')"
  if [ -z "$names" ]; then
    fail "PID 1's environment can be read"
  elif grep -qx CLOUVE_OPS_PASSWORD <<< "$names"; then
    fail "PID 1 (Apache) has no CLOUVE_OPS_PASSWORD"
  else
    pass "PID 1 (Apache) has no CLOUVE_OPS_PASSWORD"
  fi
  # shellcheck disable=SC2016  # the script is for the bash in the container
  who="$(docker exec -e "T_PW=$ops_pw" "$A" bash -c '
    d="$(mktemp -d)"; printf "#!/bin/sh\nprintf \"%%s\\n\" \"\$T_PW\"\n" > "$d/askpass"; chmod 700 "$d/askpass"
    SSH_ASKPASS="$d/askpass" SSH_ASKPASS_REQUIRE=force timeout 30 ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
      clouve-ops@127.0.0.1 id -un </dev/null 2>/dev/null; rm -rf "$d"')"
  assert_eq "clouve-ops still signs in over SSH" "clouve-ops" "$who"
  leaked=0
  log="$(docker logs "$A" 2>&1)"
  while IFS= read -r s; do [ -n "$s" ] && grep -qF -- "$s" <<< "$log" && leaked=$((leaked + 1)); done < "$WORK/$app.secrets"
  assert_eq "the container's log holds none of the passwords" "0" "$leaked"
  if [ "$app" = moodle ] && [ -n "$admin_var" ]; then
    admin_pw="$(sed -n "s/^$admin_var=//p" "$WORK/$app.app.env")"
    # shellcheck disable=SC2016  # PHP code
    ok="$(docker exec -e "T_U=$admin_user" -e "T_P=$admin_pw" "$A" php -r '
      define("CLI_SCRIPT", true); require "/var/www/html/config.php";
      $u = $DB->get_record("user", ["username" => core_text::strtolower(getenv("T_U"))]);
      echo ($u && validate_internal_user_password($u, getenv("T_P"))) ? "yes" : "no";' 2>/dev/null | tail -c 3)"
    assert_eq "Moodle's admin signs in with the password given at install" "yes" "$ok"
  fi
  docker rm -f -v "$A" "$D" >/dev/null 2>&1
done

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sApp container checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sApp container checks failed.%s\n' "$RED" "$RESET"
exit 1
