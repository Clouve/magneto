#!/bin/bash

# ============================================================================
# Persona host test
# ============================================================================
# Each app's persona (apps/<app>/image/context/<app>/CONTEXT.md.tpl) is pulled
# by the Magneto Agent at init and rendered with envsubst when the user's
# session starts (magneto-agent: chat/marketplace/context-composer.sh). On
# Kubernetes a sibling container is named tkt-<id>-<app>, so the bare app name
# (`gibbon`, `ai-studio`) does not resolve from the agent. The agent exports
# <APP>_HOST with the name that does (sidecar-env-fetcher.sh), and a persona
# that writes `clouve-ops@${<APP>_HOST}` renders the right host everywhere.
#
# This test renders every persona the way the agent does, with Kubernetes-style
# hosts, and checks that:
#   - it gives the SSH command for its own app host (clouve-ops@<host>);
#   - the rendered text never contains a password: not the clouve-ops one, and
#     not the app's database password, Nextcloud's admin password or Odoo's
#     master password, even with the plain envsubst of agents built before
#     2026-10-20, which filled in every variable that was set (a persona names
#     the variable that holds a password, never ${THE_VARIABLE});
#   - it fetches the clouve-ops password, the app's database password and
#     Odoo's master password with ${NAME:-$(clv-secret NAME)}, and never reads
#     one with printenv. An older agent has NAME in its environment and no
#     clv-secret. A new agent has clv-secret and no NAME. A persona ships in a
#     sibling image pinned to a dated tag, and the agent runs :latest, so it
#     can meet either one. Only the two-part form works on both: a plain
#     $(clv-secret NAME) fails on the older agent;
#   - no manifest-style placeholder ({user.firstName}, {org.name}) is left:
#     those are filled in only in clv-docker-compose.yml values, never here;
#   - the AI Studio persona says the user's work is on the workspace, never in
#     the agent's own container (the assistant once searched its own container
#     for the starter project and gave up).
#
# Needs envsubst (gettext-base). Nothing is built and no container runs.
#
# Usage: bash tests/persona-hosts.test.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$SCRIPT_DIR/../apps"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAILED=0
pass() { printf "  ${GREEN}PASS${NC} %s\n" "$1"; }
fail() { printf "  ${RED}FAIL${NC} %s\n" "$1"; FAILED=1; }
assert_contains() { if grep -qF -- "$3" <<< "$2"; then pass "$1"; else
  fail "$1"; printf '       wanted: %q\n' "$3"; fi; }
assert_not_contains() { if ! grep -qF -- "$3" <<< "$2"; then pass "$1"; else
  fail "$1"; printf '       did NOT want: %q\n' "$3"; fi; }
# assert_not_matches <label> <text> <ere>: passes when no part of the text matches.
assert_not_matches() { local hit; hit="$(grep -oE -- "$3" <<< "$2")"; if [ -z "$hit" ]; then pass "$1"; else
  fail "$1"; printf '       did NOT want: %q\n' "$hit"; fi; }

# two_part NAME: prints ${NAME:-$(clv-secret NAME)}, the form a persona fetches a password with.
two_part() { printf '${%s:-$(clv-secret %s)}' "$1" "$1"; }

command -v envsubst >/dev/null || { echo "envsubst not found (install gettext-base)"; exit 1; }

SENTINEL_PW="pw-sentinel-5c1d0b7e"

# render <template> <host-var> <host>: envsubst with only the vars the test
# sets, like a login shell that has the agent's sibling env.
render() {
  env -i PATH="$PATH" "$2=$3" CLOUVE_OPS_PASSWORD="$SENTINEL_PW" USERNAME=Test_User \
    GIBBON_DB_PASSWORD="$SENTINEL_PW-gibbon-db" MOODLE_DB_PASSWORD="$SENTINEL_PW-moodle-db" \
    ODOO_DB_PASSWORD="$SENTINEL_PW-odoo-db" ODOO_MASTER_PASSWORD="$SENTINEL_PW-odoo-master" \
    WORDPRESS_DB_PASSWORD="$SENTINEL_PW-wordpress-db" ROOT_PASSWORD="$SENTINEL_PW-root" \
    NEXTCLOUD_DB_PASSWORD="$SENTINEL_PW-nextcloud-db" NEXTCLOUD_ADMIN_PASSWORD="$SENTINEL_PW-nextcloud-admin" \
    envsubst < "$1"
}

found=0
for tpl in "$APPS_DIR"/*/image/context/*/CONTEXT.md.tpl; do
  [ -f "$tpl" ] || continue
  found=$((found + 1))
  app="$(basename "$(dirname "$tpl")")"            # ai-studio
  var="$(printf '%s' "$app" | tr '[:lower:]-' '[:upper:]_')_HOST"   # AI_STUDIO_HOST
  host="tkt-7-$app"
  out="$(render "$tpl" "$var" "$host")"

  echo "$app (\${$var} = $host)"
  assert_contains "$app: SSH command names the app host" "$out" "clouve-ops@$host"
  assert_not_contains "$app: no bare-name SSH host" "$out" "clouve-ops@$app "
  assert_not_contains "$app: clouve-ops password stays out of the text" "$out" "$SENTINEL_PW"
  assert_not_contains "$app: no manifest-style {user.*} placeholder" "$out" "{user."
  assert_not_contains "$app: no manifest-style {org.*} placeholder" "$out" "{org."
  # SSHPASS comes from the two-part form, either exported once or set on the sshpass command itself. The assistant's
  # shell keeps no variables from one command to the next, so the per-command form is the one that always works.
  ops_form="$(two_part CLOUVE_OPS_PASSWORD)"
  if grep -qF -- "export SSHPASS=\"$ops_form\"" <<< "$out" || grep -qF -- "SSHPASS=\"$ops_form\" sshpass -e" <<< "$out"; then
    pass "$app: sets SSHPASS from the two-part form of the clouve-ops password"
  else
    fail "$app: sets SSHPASS from the two-part form of the clouve-ops password"
    printf '       wanted: %q or %q\n' "export SSHPASS=\"$ops_form\"" "SSHPASS=\"$ops_form\" sshpass -e"
  fi
  if [ "$app" = "nextcloud" ]; then
    assert_not_contains "nextcloud: sets SSHPASS on each sshpass command, never with export" "$out" "export SSHPASS"
  fi
  # printenv CLOUVE_OPS_PASSWORD, printenv <APP>_DB_PASSWORD, printenv ODOO_MASTER_PASSWORD: none of them.
  assert_not_matches "$app: never reads a password with printenv" "$out" 'printenv[[:space:]]+[A-Z0-9_]*PASSWORD'
  case "$app" in
    gibbon|moodle|nextcloud|odoo|wordpress)
      dbvar="$(printf '%s' "$app" | tr '[:lower:]-' '[:upper:]_')_DB_PASSWORD"
      assert_contains "$app: names the variable that holds the database password" "$out" "\`$dbvar\`"
      assert_contains "$app: fetches the database password in the two-part form" "$out" "$(two_part "$dbvar")"
      ;;
  esac
  if [ "$app" = "odoo" ]; then
    assert_contains "odoo: names the variable that holds the master password" "$out" "\`ODOO_MASTER_PASSWORD\`"
    assert_contains "odoo: fetches the master password in the two-part form" "$out" "$(two_part ODOO_MASTER_PASSWORD)"
  fi
  # Every clv-secret call sits inside the two-part form for its own name. Take those out and none is left.
  rest="$out"
  for name in $(grep -oE '\$\(clv-secret [A-Za-z0-9_]+\)' <<< "$out" | sed -E 's/^.* ([A-Za-z0-9_]+)\)$/\1/' | sort -u); do
    form="$(two_part "$name")"
    rest="${rest//"$form"/}"
  done
  assert_not_matches "$app: no clv-secret call outside the two-part form" "$rest" '\$\(clv-secret [A-Za-z0-9_]+\)'

  if [ "$app" = "ai-studio" ]; then
    assert_contains "ai-studio: the starter project is placed on the workspace host" "$out" \
      "/home/clouve-ops/projects/@SLUG@/\` on \`$host\`"
    assert_contains "ai-studio: says the user's work is not in the agent's container" "$out" \
      "None of it is in this container"
  fi
done

if [ "$found" -eq 0 ]; then
  fail "no persona templates found under $APPS_DIR"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf "${GREEN}All persona host checks passed (%d personas).${NC}\n" "$found"
else
  printf "${RED}Persona host checks failed.${NC}\n"
fi
exit "$FAILED"
