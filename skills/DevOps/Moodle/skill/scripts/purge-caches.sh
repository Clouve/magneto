#!/usr/bin/env bash
# Moodle DevOps Skill — purge-caches.sh
#
# Wraps admin/cli/purge_caches.php. Run this after:
#   - Plugin install / uninstall / upgrade
#   - config.php edits
#   - Theme cache mode changes
#   - Language pack updates
#
# Env vars read:
#   MOODLE_HOST          — pod-internal hostname of moodle container
#   CLOUVE_OPS_PASSWORD  — for sshpass -e
#
# Exit codes:
#   0 — purge completed
#   1 — required env missing
#   2 — admin/cli/purge_caches.php returned non-zero

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [--muc] [--theme] [--lang] [--js] [--filter] [--other]
                       [--courses=ID1,ID2,...]
                       [-h|--help]

Without flags: purges everything. With one or more flags: targeted purge.

See:
  https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/purge_caches.php
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage; exit 0
fi

: "${MOODLE_HOST:?MOODLE_HOST not set}"
: "${CLOUVE_OPS_PASSWORD:?CLOUVE_OPS_PASSWORD not set}"

# Validate flags — only pass through known purge_caches.php options.
flags=()
for arg in "$@"; do
    case "${arg}" in
        --muc|--theme|--lang|--js|--filter|--other) flags+=("${arg}") ;;
        --courses=*) flags+=("${arg}") ;;
        *)
            echo "ERROR: unrecognised flag: ${arg}" >&2
            usage
            exit 1
            ;;
    esac
done

ssh_opts=(-o StrictHostKeyChecking=accept-new -o BatchMode=no -o ConnectTimeout=10)
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Purging caches on ${MOODLE_HOST}${flags[*]:+ }${flags[*]:-(all)}..." >&2

if ! SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" \
        "clouve-ops@${MOODLE_HOST}" \
        "sudo -u www-data php /var/www/html/admin/cli/purge_caches.php ${flags[*]}"; then
    echo "ERROR: purge_caches.php returned non-zero" >&2
    exit 2
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Purge complete. Users may need to hard-reload (Cmd-Shift-R / Ctrl-Shift-R)." >&2
