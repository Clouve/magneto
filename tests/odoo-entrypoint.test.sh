#!/bin/bash

# ============================================================================
# Odoo entrypoint: what it writes into odoo.conf and takes out of Odoo's
# environment, checked without Docker
# ============================================================================
# apps/odoo/image/installer/lib.sh holds what entrypoint.sh and install.sh
# share:
#   - _clv_is_secret_name, the rule for what a secret's name is. It is a copy
#     of magneto-agent's (image/installer/secrets/secrets-lib.sh), so the test
#     runs the same name table as magneto-agent's
#     tests/installer/secrets/secrets.test.sh, and compares the two functions
#     byte for byte when a magneto-agent checkout sits next to this repo;
#   - odoo_unset_secrets, which unsets every exported variable the rule calls
#     a secret, and PGPASSWORD (one word, so the rule doesn't match it, and
#     Odoo 19 reads it into db_password above odoo.conf). The entrypoint runs
#     it before Odoo starts, and install.sh before its odoo commands, so no
#     password, the platform's or any other, reaches a process of odoo's;
#   - odoo_dbfilter, the dbfilter that lets a browser reach the deployment's
#     database only. It refuses a name Odoo's database manager would refuse
#     (DBNAME_PATTERN in addons/web/controllers/database.py).
#
# It also renders the odoo.conf heredoc out of entrypoint.sh (as
# tests/odoo-addons-path.test.sh does) and reads it the way Odoo 19 does:
# list_db is false (the database manager is locked at every start), dbfilter
# matches only the deployment's database under Odoo's own matching (re.match,
# http.py db_filter), and there is no db_name (Odoo 19 creates a missing
# db_name database at every start, with the admin password "admin").
#
# And it checks three things in the scripts' text: the entrypoint's refusal
# of a bad ODOO_DB_NAME doesn't print the value; every setpriv in the
# entrypoint runs under `env -i PATH="$PATH"` (the markers it writes as odoo
# need nothing else); and the Dockerfile copies every installer file the
# scripts source (it copies them by name).
#
# Needs bash and python3. Nothing is built and no container runs.
#
# Usage: bash tests/odoo-entrypoint.test.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_DIR="$REPO_DIR/apps/odoo/image"
LIB="$IMAGE_DIR/installer/lib.sh"
ENTRYPOINT="$IMAGE_DIR/installer/entrypoint.sh"
INSTALL="$IMAGE_DIR/installer/install.sh"
DOCKERFILE="$IMAGE_DIR/Dockerfile"
AGENT_LIB="$REPO_DIR/../magneto-agent/image/installer/secrets/secrets-lib.sh"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'

FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }
assert_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else
    fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi
}
finish() {
  echo
  if [ "$FAILED" -eq 0 ]; then echo "All Odoo entrypoint checks passed."; exit 0; fi
  echo "Some Odoo entrypoint checks FAILED."
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Odoo entrypoint: odoo.conf's lock, and the secrets Odoo never gets"

if [ ! -r "$LIB" ]; then
  fail "apps/odoo/image/installer/lib.sh exists"
  finish
fi

# --- 1. the rule for a secret's name -------------------------------------------
# rule_of NAME...: prints NAME:<exit status of _clv_is_secret_name> for each.
rule_of() {
  bash -c '. "$1"; shift; for n; do _clv_is_secret_name "$n"; echo "$n:$?"; done' _ "$LIB" "$@" 2>/dev/null
}
# expect_rule <label> <wanted status> NAME...
expect_rule() {
  local label="$1" want="$2" got n wrong=""
  shift 2
  got="$(rule_of "$@")"
  for n in "$@"; do grep -qxF "$n:$want" <<<"$got" || wrong="$wrong $n"; done
  if [ -z "$wrong" ]; then pass "$label"; else fail "$label"; echo "       wrong:$wrong"; fi
}
# The table from magneto-agent's tests/installer/secrets/secrets.test.sh.
expect_rule "the rule calls magneto-agent's secret names secrets" 0 \
  MYSQL_PASSWORD MYSQL_ROOT_PASSWORD DB_PASSWORD MOODLE_PASSWORD GIBBON_PASSWORD \
  ODOO_ADMIN_PASSWORD ODOO_DB_PASSWORD ODOO_MASTER_PASSWORD POSTGRES_PASSWORD WORDPRESS_ADMIN_PASSWORD \
  WORDPRESS_DB_PASSWORD MOODLE_GIBBON_DB_PASSWORD CLOUVE_OPS_PASSWORD MAGNETO_AGENT_PASSWORD \
  MAGNETO_AGENT_ROOT_PASSWORD MAGNETO_AGENT_SKILLS_GIT_TOKEN CLV_STUDIO_JWT_SIGNING_KEY \
  MOODLE_MYSQL_MYSQL_ROOT_PASSWORD SMTP_PWD DB_PASS STRIPE_SECRET SSH_PRIVATE_KEY X_AUTH \
  APP_PASSWORDS LDAP_PASSWD APP_SECRETS API_KEYS REFRESH_TOKENS DB_CREDENTIAL GCP_CREDENTIALS SSH_PRIVATE \
  T_API_TOKEN db_password Gibbon_Db_Password smtp_pwd
expect_rule "the rule leaves magneto-agent's plain names alone" 1 \
  MAGNETO_AGENT_LLM_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN MAGNETO_AGENT_LLM_BASE_URL MOODLE_DB_HOST \
  MOODLE_DB_USER MOODLE_DB_NAME MOODLE_USERNAME PASSWORDLESS_MODE KEYCLOAK_URL AUTHOR_NAME MONKEY TOKENIZER_PATH \
  magneto_agent_llm_key keycloak_url passwordless_mode PGPASSWORD ODOO_DB_NAME ODOO_RC PATH

# function_body FILE: the _clv_is_secret_name function as FILE writes it.
function_body() { awk '/^_clv_is_secret_name\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$1"; }
if [ -r "$AGENT_LIB" ]; then
  body="$(function_body "$AGENT_LIB")"
  if [ -n "$body" ] && [ "$body" = "$(function_body "$LIB")" ]; then
    pass "_clv_is_secret_name is magneto-agent's, byte for byte (../magneto-agent)"
  else
    fail "_clv_is_secret_name is magneto-agent's, byte for byte (../magneto-agent)"
    diff <(printf '%s\n' "$body") <(function_body "$LIB") | sed 's/^/       /' | head -20
  fi
else
  echo "  - skipped the byte-for-byte check: no magneto-agent checkout next to magneto"
fi

# lib.sh is only ever sourced, so it names its shell for shellcheck itself.
if command -v shellcheck >/dev/null 2>&1; then
  if out="$(shellcheck "$LIB" 2>&1)"; then
    pass "shellcheck finds nothing in lib.sh, with no shell given on the command line"
  else
    fail "shellcheck finds nothing in lib.sh, with no shell given on the command line"
    printf '%s\n' "$out" | grep -E '^In |SC[0-9]+' | head -n 4 | sed 's/^/       /'
  fi
else
  echo "  - skipped the shellcheck run on lib.sh: no shellcheck on this machine"
fi

# --- 2. odoo_unset_secrets -----------------------------------------------------
# A clean bash with the container's kind of environment: the platform's passwords, a PGPASSWORD, a token of some other
# app's, and the settings Odoo and the scripts need. install.sh keeps its own copies in shell variables that aren't
# exported, and those must stay.
# shellcheck disable=SC2016  # the script is for the bash that env -i starts
result="$(env -i PATH=/usr/bin:/bin HOME=/root LANG=C.UTF-8 ODOO_RC=/etc/odoo/odoo.conf ODOO_DB_HOST=db \
  ODOO_DB_NAME=odoo ODOO_URL=http://odoo.example ODOO_DB_USER=odoo \
  ODOO_DB_PASSWORD=x1 ODOO_MASTER_PASSWORD=x2 ODOO_ADMIN_PASSWORD=x3 CLOUVE_OPS_PASSWORD=x4 PGPASSWORD=x5 \
  T_API_TOKEN=x6 db_password=x7 SMTP_PWD=x8 X_AUTH=x9 \
  bash -c '. "$1" || exit 9; DB_PASSWORD=kept; out="$(odoo_unset_secrets)"; printf "out=[%s]\n" "$out";
    odoo_unset_secrets; compgen -e | sort; echo "local DB_PASSWORD=${DB_PASSWORD:-gone}"' _ "$LIB" 2>&1)"
left="$(grep -vE '^(out=|local )' <<<"$result" | tr '\n' ' ')"
gone=""
for n in ODOO_DB_PASSWORD ODOO_MASTER_PASSWORD ODOO_ADMIN_PASSWORD CLOUVE_OPS_PASSWORD PGPASSWORD T_API_TOKEN \
    db_password SMTP_PWD X_AUTH; do
  [[ " $left " == *" $n "* ]] && gone="$gone $n"
done
if [ -z "$gone" ]; then pass "odoo_unset_secrets takes out every secret name and PGPASSWORD"; else
  fail "odoo_unset_secrets takes out every secret name and PGPASSWORD"; echo "       still there:$gone"; fi
kept=""
for n in PATH HOME LANG ODOO_RC ODOO_DB_HOST ODOO_DB_NAME ODOO_URL ODOO_DB_USER; do
  [[ " $left " == *" $n "* ]] || kept="$kept $n"
done
if [ -z "$kept" ]; then pass "it keeps what Odoo and the scripts need (PATH, LANG, ODOO_RC, ODOO_DB_HOST, ...)"; else
  fail "it keeps what Odoo and the scripts need (PATH, LANG, ODOO_RC, ODOO_DB_HOST, ...)"; echo "       gone:$kept"; fi
assert_eq "it leaves a shell variable that isn't exported (install.sh's own DB_PASSWORD)" "local DB_PASSWORD=kept" \
  "$(grep '^local ' <<<"$result")"
assert_eq "it prints nothing" "out=[]" "$(grep '^out=' <<<"$result")"

# --- 3. odoo_dbfilter ----------------------------------------------------------
dbfilter_of() { bash -c '. "$1"; odoo_dbfilter "$2"' _ "$LIB" "$1" 2>/dev/null; }
assert_eq "odoo_dbfilter odoo" '^odoo\Z' "$(dbfilter_of odoo)"
assert_eq "odoo_dbfilter escapes dots: my.db-1" '^my\.db-1\Z' "$(dbfilter_of my.db-1)"
refused=""
for bad in '' a -x 'x y' x/y 'x$' "odoo"$'\n' '.odoo' 'od*' 'od\o'; do
  if bash -c '. "$1"; odoo_dbfilter "$2"' _ "$LIB" "$bad" >/dev/null 2>&1; then refused="$refused $(printf '%q' "$bad")"; fi
done
if [ -z "$refused" ]; then pass "odoo_dbfilter refuses names Odoo's database manager refuses"; else
  fail "odoo_dbfilter refuses names Odoo's database manager refuses"; echo "       accepted:$refused"; fi

# --- 4. the odoo.conf the entrypoint writes ---------------------------------------
HEREDOC="$(awk '
  /^cat > "\$ODOO_CONF" <<EOF$/ { inside = 1; next }
  inside && /^EOF$/ { exit }
  inside { print }
' "$ENTRYPOINT")"
if [[ -z "$HEREDOC" ]]; then
  fail "found the odoo.conf heredoc in entrypoint.sh"
  finish
fi
# The heredoc as the entrypoint renders it, with the dbfilter odoo_dbfilter makes for "odoo".
ODOO_DBFILTER="$(dbfilter_of odoo)" DB_HOST=odoo-postgres DB_PORT=5432 DB_USER=odoo DB_PASSWORD=not-a-real-password \
  ODOO_DATA_DIR=/var/lib/odoo bash -c "cat <<EOF
$HEREDOC
EOF" > "$WORK/odoo.conf"

conf_read="$(python3 -I - "$WORK/odoo.conf" <<'PY'
import configparser, re, sys
p = configparser.RawConfigParser()
p.read(sys.argv[1])
o = dict(p.items('options'))
# odoo/tools/config.py _check_bool, which reads store_false options such as list_db from the file
def check_bool(v):
    if v.lower() in ('1', 'yes', 'true', 'on'): return True
    if v.lower() in ('0', 'no', 'false', 'off'): return False
    return 'invalid'
print('list_db=%s' % (check_bool(o['list_db']) if 'list_db' in o else 'missing'))
print('db_name=%s' % ('present' if 'db_name' in o else 'absent'))
f = o.get('dbfilter', '')
print('dbfilter=%s' % f)
# http.py db_filter: re.compile(dbfilter).match(db), after %h/%d substitution (none here)
rx = re.compile(f) if f else None
for db in ['odoo', 'odoo_staging', 'xodoo', 'odoo2', 't-second', 'odoo\n', 'ODOO']:
    print('match %r=%s' % (db, bool(rx and rx.match(db))))
PY
)"
assert_eq "odoo.conf locks the database manager: list_db reads False, as Odoo parses it" "list_db=False" \
  "$(grep '^list_db=' <<<"$conf_read")"
assert_eq "odoo.conf pins the database with dbfilter (^odoo\\Z)" 'dbfilter=^odoo\Z' "$(grep '^dbfilter=' <<<"$conf_read")"
assert_eq "odoo.conf has no db_name (Odoo 19 would re-create a missing one with admin/admin)" "db_name=absent" \
  "$(grep '^db_name=' <<<"$conf_read")"
assert_eq "under Odoo's match the filter passes odoo and nothing else" \
  "match 'odoo'=True match 'odoo_staging'=False match 'xodoo'=False match 'odoo2'=False match 't-second'=False match 'odoo\\n'=False match 'ODOO'=False" \
  "$(grep '^match ' <<<"$conf_read" | tr '\n' ' ' | sed 's/ $//')"

# --- 5. the scripts' text -----------------------------------------------------------
refusal="$(grep -n "isn't a database name" "$ENTRYPOINT" || true)"
if [ -n "$refusal" ] && ! grep -qE '\$\{?(ODOO_)?DB_NAME' <<<"$refusal"; then
  pass "the refusal of a bad ODOO_DB_NAME names the rule and prints no value"
else
  fail "the refusal of a bad ODOO_DB_NAME names the rule and prints no value"
  echo "       ${refusal:-no refusal line found}"
fi

setprivs="$(grep -nE '(^|[^-])setpriv ' "$ENTRYPOINT" | grep -v '^[0-9]*:[[:space:]]*#' || true)"
# shellcheck disable=SC2016  # a literal: the text the entrypoint must hold
bare="$(grep -vF 'env -i PATH="$PATH" setpriv' <<<"$setprivs" || true)"
if [ -n "$setprivs" ] && [ -z "$bare" ]; then
  pass "every setpriv in the entrypoint runs under env -i PATH=\"\$PATH\" ($(grep -c . <<<"$setprivs"))"
else
  fail "every setpriv in the entrypoint runs under env -i PATH=\"\$PATH\""
  printf '%s\n' "${bare:-no setpriv found}" | sed 's/^/       /'
fi

for script in "$ENTRYPOINT" "$INSTALL"; do
  name="${script##*/}"
  if grep -qE '^[[:space:]]*odoo_unset_secrets[[:space:]]*$' "$script" \
      && ! grep -qE '^[[:space:]]*unset[[:space:]].*PASSWORD' "$script"; then
    pass "$name takes the secrets out with odoo_unset_secrets, not a fixed list"
  else
    fail "$name takes the secrets out with odoo_unset_secrets, not a fixed list"
  fi
done

missing=""
while IFS= read -r file; do
  grep -qE "^COPY installer/$file /clouve/odoo/installer/" "$DOCKERFILE" || missing="$missing $file"
done < <(grep -hoE '^[[:space:]]*(\.|source)[[:space:]]+/clouve/odoo/installer/[A-Za-z0-9_.-]+' "$ENTRYPOINT" "$INSTALL" \
  | sed 's#.*/##' | sort -u)
sourced="$(grep -hE '^[[:space:]]*(\.|source)[[:space:]]+/clouve/odoo/installer/' "$ENTRYPOINT" "$INSTALL" | grep -c . || true)"
if [ "$sourced" -gt 0 ] && [ -z "$missing" ]; then
  pass "the Dockerfile copies every installer file the scripts source ($sourced sourced)"
else
  fail "the Dockerfile copies every installer file the scripts source"
  echo "       sourced: $sourced, not copied:${missing:- none}"
fi

finish
