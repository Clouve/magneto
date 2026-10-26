#!/bin/bash
# ============================================================================
# Odoo persona: commands the AI Assistant can run as written
# ============================================================================
# apps/odoo/image/context/odoo/CONTEXT.md.tpl becomes the AI Assistant's
# CLAUDE.md, so it must give the same command shapes as the Odoo skill
# (magneto-skills/plugins/odoo). Each rule below is a shape that fails or
# leaks on Clouve's Odoo 19 image:
#
#   1. Printing /etc/odoo/odoo.conf whole. It holds db_password and the
#      master password (admin_passwd) in plain text.
#   2. Running the skill's backup.sh in the agent. It runs inside the Odoo
#      container, piped over ssh: "sudo bash -s -- <db>" < .../backup.sh.
#   3. `-c` given to `odoo db`. `odoo db dump -c ...` fails ("unrecognized
#      arguments: -c"); ODOO_RC=/etc/odoo/odoo.conf works for every subcommand.
#   4. Recycling the pod, or asking the customer to restart. The agent has no
#      kubectl and the customer's dashboard has no restart button. Odoo is
#      PID 1 in its container and re-executes itself on SIGHUP.
#   5. An odoo command given -d (shell, module, neutralize, -i/-u) without the
#      config. sudo over ssh has no ODOO_RC, so Odoo can't find the database:
#      `odoo neutralize -d <db>` ends "THE DATABASE IS NOT NEUTRALIZED!".
#
# Plus positive checks: restarts are `kill -HUP 1`, and every
# /clouve/skills/odoo/plugin/<path> the persona names exists in the sibling
# magneto-skills checkout (skipped when there is none).
#
# Reads files only. Nothing runs, no network, no Docker.
#
# Usage: bash tests/odoo-persona-commands.test.sh   (exit 0 = all pass)
# ============================================================================

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
persona="${here}/../apps/odoo/image/context/odoo/CONTEXT.md.tpl"
skills_plugin="${here}/../../magneto-skills/plugins/odoo"

pass=0
fail=0

ok()  { printf '  ✓ %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      | /' | cut -c1-200; fail=$((fail + 1)); }

# rule <label> <ere> [<exclude-ere>]: passes when no persona line matches <ere>
# (case-insensitive) other than lines that also match <exclude-ere>.
rule() {
  local label="$1" ere="$2" exclude="${3:-}" found
  if [ -n "${exclude}" ]; then
    found="$(grep -n -i -E -- "${ere}" "${persona}" | grep -v -E -- "${exclude}" || true)"
  else
    found="$(grep -n -i -E -- "${ere}" "${persona}" || true)"
  fi
  if [ -z "${found}" ]; then ok "${label}"; else bad "${label}" "${found}"; fi
}

# has <label> <ere>: passes when some persona line matches <ere>.
has() {
  if grep -q -E -- "$2" "${persona}"; then ok "$1"; else bad "$1" "no line matches: $2"; fi
}

echo "Odoo persona: command shapes"

rule "no command prints odoo.conf whole (it holds db_password and admin_passwd)" \
  '(cat|less|more|head|tail|bat)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*/etc/odoo/odoo\.conf'

rule "backup.sh is piped into the Odoo container, never run in the agent" \
  'scripts/backup\.sh' \
  'bash -s'

odoo='odoo(-bin)?'
cfg='(-c|--config)([[:space:]=]|$)'
rule "no 'odoo db' command takes -c (use ODOO_RC=/etc/odoo/odoo.conf)" \
  "${odoo}[[:space:]]+db[[:space:]]+${cfg}|${odoo}[[:space:]]+(-c|--config)[[:space:]=][^[:space:]]+[[:space:]]+db([[:space:]]|$)|${odoo}[[:space:]]+db[[:space:]]+(init|load|dump|duplicate|rename|drop)([[:space:]][^|;&\`]*)?[[:space:]]${cfg}"

rule "no step recycles the pod or asks the customer to restart" \
  'kubectl[[:space:]]+(rollout|delete[[:space:]]+pod)|recycle[[:space:]]+(the|your|its)[[:space:]]+pod|pod[[:space:]/-]+(container[[:space:]]+)?recycle|restart(ing)?[[:space:]]+(the|your)[[:space:]]+deployment|ask[[:space:]]+the[[:space:]]+(customer|user|tenant)[[:space:]]+to[[:space:]]+restart'

rule "every odoo command given -d (shell, module, neutralize, -i/-u) passes the config" \
  "${odoo}[[:space:]]+(shell|module[[:space:]]+[a-z]+|neutralize)[^\`]*[[:space:]]-d[[:space:]]|${odoo}[[:space:]]+-d[[:space:]]" \
  "[[:space:]]${cfg}|ODOO_RC="

has "restarts Odoo in place with SIGHUP to PID 1" 'kill -HUP 1'

if [ -d "${skills_plugin}" ]; then
  missing=""
  while IFS= read -r ref; do
    rel="${ref#/clouve/skills/odoo/plugin/}"
    rel="${rel%.}"
    [ -e "${skills_plugin}/${rel}" ] || missing+="missing: ${ref}"$'\n'
  done < <(grep -h -o -E '/clouve/skills/odoo/plugin/[A-Za-z0-9_./-]*' "${persona}" | sort -u)
  if [ -z "${missing}" ]; then
    ok "every /clouve/skills/odoo/plugin/... path the persona names ships in magneto-skills"
  else
    bad "every /clouve/skills/odoo/plugin/... path the persona names ships in magneto-skills" "${missing%$'\n'}"
  fi
else
  echo "  - skipped the skill-path check: no magneto-skills checkout next to magneto"
fi

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
