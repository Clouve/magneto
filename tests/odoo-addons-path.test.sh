#!/bin/bash

# ============================================================================
# Odoo addons_path test
# ============================================================================
# The Odoo image's entrypoint (apps/odoo/image/installer/entrypoint.sh) writes
# /etc/odoo/odoo.conf on every start, including addons_path. The listing gives
# /mnt/extra-addons its own volume for custom modules, and it stays empty until
# a customer adds one. Odoo 19 checks every addons_path entry each time it
# reads the config (odoo/tools/config.py, _check_addons_path):
#   - a plain folder that holds no module logs "invalid addons directory ...,
#     skipped" (every server start and every odoo command);
#   - an entry with glob characters is expanded with glob.glob(), and matches
#     that hold no module are skipped without a word.
# So the entrypoint must name /mnt/extra-addons through a pattern, which Odoo
# re-checks at every start: quiet while the folder is empty, loaded once a
# module is in it.
#
# This test pulls the odoo.conf heredoc out of the entrypoint, renders it with
# bash using made-up database values, reads addons_path the way Odoo does
# (configparser, comma-separated), and checks that:
#   - the core addons folder is still listed;
#   - /mnt/extra-addons appears only as a glob pattern that matches it (no
#     plain entry);
#   - applying Odoo 19's rule to a sandbox copy of /mnt: the pattern is
#     skipped quietly while the folder is empty or holds files that aren't
#     modules, and it yields /mnt/extra-addons once a module folder
#     (__init__.py + __manifest__.py) is in it.
#
# Needs python3. Nothing is built and no container runs.
#
# Usage: bash tests/odoo-addons-path.test.sh [path/to/entrypoint.sh]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${1:-$SCRIPT_DIR/../apps/odoo/image/installer/entrypoint.sh}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAILED=0
pass() { printf "  ${GREEN}PASS${NC} %s\n" "$1"; }
fail() { printf "  ${RED}FAIL${NC} %s\n" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Odoo entrypoint: addons_path in the odoo.conf it writes"

# ---------------------------------------------------------------------------
# Extract and render the heredoc that writes $ODOO_CONF
# ---------------------------------------------------------------------------
HEREDOC="$(awk '
  /^cat > "\$ODOO_CONF" <<EOF$/ { inside = 1; next }
  inside && /^EOF$/ { exit }
  inside { print }
' "$ENTRYPOINT")"
if [[ -z "$HEREDOC" ]]; then
  fail "found the odoo.conf heredoc in $ENTRYPOINT"
  exit 1
fi

RENDERED="$WORK/odoo.conf"
DB_HOST=odoo-postgres DB_PORT=5432 DB_USER=odoo DB_PASSWORD=not-a-real-password \
  ODOO_DATA_DIR=/var/lib/odoo \
  bash -c "cat <<EOF
$HEREDOC
EOF" > "$RENDERED"

ENTRIES="$(python3 -I - "$RENDERED" <<'PY'
import configparser, sys
p = configparser.RawConfigParser()
p.read(sys.argv[1])
for entry in p.get('options', 'addons_path').split(','):
    if entry.strip():
        print(entry.strip())
PY
)"
printf '  addons_path entries:\n'
printf '%s\n' "$ENTRIES" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# What the entrypoint writes
# ---------------------------------------------------------------------------
if grep -qxF "/usr/lib/python3/dist-packages/odoo/addons" <<< "$ENTRIES"; then
  pass "lists the core addons folder"
else
  fail "lists the core addons folder"
fi

if grep -qxF "/mnt/extra-addons" <<< "$ENTRIES" || grep -qxF "/mnt/extra-addons/" <<< "$ENTRIES"; then
  fail "has no plain /mnt/extra-addons entry (Odoo warns about it while it is empty)"
else
  pass "has no plain /mnt/extra-addons entry (Odoo warns about it while it is empty)"
fi

PATTERNS="$(python3 -I - "$ENTRIES" <<'PY'
import fnmatch, glob, sys
for entry in sys.argv[1].splitlines():
    if glob.has_magic(entry) and fnmatch.fnmatchcase('/mnt/extra-addons', entry):
        print(entry)
PY
)"
assert_eq "names /mnt/extra-addons through exactly one glob pattern" "1" "$(grep -c . <<< "$PATTERNS")"

# ---------------------------------------------------------------------------
# Odoo 19's rule, applied to a sandbox /mnt
# ---------------------------------------------------------------------------
# odoo_reads <sandbox-root> — applies Odoo 19's _check_addons_path to every
# entry that names /mnt/extra-addons (plain or pattern), re-rooted in the
# sandbox, and prints one line per entry: "kept <paths>", "skipped quietly",
# or "warned".
odoo_reads() {
  python3 -I - "$1" "$ENTRIES" <<'PY'
import fnmatch, glob, os, sys
root, entries = sys.argv[1], sys.argv[2].splitlines()

def is_addons_path(p):  # odoo/tools/config.py _is_addons_path
    for f in os.listdir(p):
        modpath = os.path.join(p, f)
        if os.path.isfile(os.path.join(modpath, '__init__.py')) and \
           os.path.isfile(os.path.join(modpath, '__manifest__.py')):
            return True
    return False

for entry in entries:
    if entry.rstrip('/') != '/mnt/extra-addons' and not (
            glob.has_magic(entry) and fnmatch.fnmatchcase('/mnt/extra-addons', entry)):
        continue
    path = root + entry  # entries are absolute: re-root them in the sandbox
    # odoo/tools/config.py _check_addons_path
    if glob.has_magic(path):
        kept = sorted(p for p in glob.glob(path) if os.path.isdir(p) and is_addons_path(p))
        print("kept " + " ".join(p[len(root):] for p in kept) if kept else "skipped quietly")
    elif not os.path.isdir(path) or not is_addons_path(path):
        print("warned")
    else:
        print("kept " + path[len(root):])
PY
}

SANDBOX="$WORK/root"
mkdir -p "$SANDBOX/mnt/extra-addons"
assert_eq "empty /mnt/extra-addons: skipped without a warning" "skipped quietly" "$(odoo_reads "$SANDBOX")"

printf 'notes\n' > "$SANDBOX/mnt/extra-addons/README.txt"
mkdir -p "$SANDBOX/mnt/extra-addons/lost+found"
assert_eq "no module in it yet (stray file, lost+found): still skipped without a warning" \
  "skipped quietly" "$(odoo_reads "$SANDBOX")"

mkdir -p "$SANDBOX/mnt/extra-addons/acme_custom"
: > "$SANDBOX/mnt/extra-addons/acme_custom/__init__.py"
printf "{'name': 'Acme custom', 'depends': ['base']}\n" > "$SANDBOX/mnt/extra-addons/acme_custom/__manifest__.py"
assert_eq "a module in /mnt/extra-addons: the folder is loaded" "kept /mnt/extra-addons" "$(odoo_reads "$SANDBOX")"

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "All addons_path checks passed."
else
  echo "Some addons_path checks FAILED."
fi
exit "$FAILED"
