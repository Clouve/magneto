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
#   - the rendered text never contains the clouve-ops password;
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

command -v envsubst >/dev/null || { echo "envsubst not found (install gettext-base)"; exit 1; }

SENTINEL_PW="pw-sentinel-5c1d0b7e"

# render <template> <host-var> <host>: envsubst with only the vars the test
# sets, like a login shell that has the agent's sibling env.
render() {
  env -i PATH="$PATH" "$2=$3" CLOUVE_OPS_PASSWORD="$SENTINEL_PW" USERNAME=Test_User \
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
