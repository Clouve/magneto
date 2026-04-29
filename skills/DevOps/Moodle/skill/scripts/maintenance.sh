#!/usr/bin/env bash
# Moodle DevOps Skill — maintenance.sh
#
# Wraps admin/cli/maintenance.php to enable / disable / query Moodle's
# maintenance mode. Just a convenience over the SSH hop.
#
# When in maintenance mode, only admins can log in; everyone else sees
# a "Site is undergoing maintenance" page. Use this before:
#   - Upgrades
#   - Coordinated DB + dataroot snapshots
#   - Long-running data migrations
#
# Env vars read:
#   MOODLE_HOST          — pod-internal hostname of moodle container
#   CLOUVE_OPS_PASSWORD  — for sshpass -e
#
# Exit codes:
#   0 — operation succeeded
#   1 — required env missing
#   2 — invalid arguments
#   3 — admin/cli/maintenance.php returned non-zero

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  on              Enable maintenance mode immediately.
  on-in MINS      Enable maintenance mode in MINS minutes.
  off             Disable maintenance mode.
  status          Print current state.
  -h, --help      This message.

Env required:
  MOODLE_HOST, CLOUVE_OPS_PASSWORD
EOF
}

if [[ $# -lt 1 ]]; then usage; exit 2; fi

cmd="$1"; shift || true

case "${cmd}" in
    -h|--help) usage; exit 0 ;;
esac

: "${MOODLE_HOST:?MOODLE_HOST not set}"
: "${CLOUVE_OPS_PASSWORD:?CLOUVE_OPS_PASSWORD not set}"

ssh_opts=(-o StrictHostKeyChecking=accept-new -o BatchMode=no -o ConnectTimeout=10)
moodle_cli() {
    SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" \
        "clouve-ops@${MOODLE_HOST}" \
        "sudo -u www-data php /var/www/html/admin/cli/maintenance.php $*"
}

case "${cmd}" in
    on)
        echo "Enabling maintenance mode..." >&2
        moodle_cli --enable || { echo "ERROR: --enable returned non-zero" >&2; exit 3; }
        ;;
    on-in)
        mins="${1:-}"
        if [[ -z "${mins}" || ! "${mins}" =~ ^[0-9]+$ ]]; then
            echo "ERROR: 'on-in' requires a positive integer (minutes)" >&2
            usage; exit 2
        fi
        echo "Enabling maintenance mode in ${mins} minutes..." >&2
        moodle_cli --enablelater="${mins}" || { echo "ERROR: --enablelater returned non-zero" >&2; exit 3; }
        ;;
    off)
        echo "Disabling maintenance mode..." >&2
        moodle_cli --disable || { echo "ERROR: --disable returned non-zero" >&2; exit 3; }
        ;;
    status)
        # admin/cli/maintenance.php with no flags prints current status.
        moodle_cli || { echo "ERROR: status query returned non-zero" >&2; exit 3; }
        ;;
    *)
        echo "ERROR: unknown command: ${cmd}" >&2
        usage; exit 2
        ;;
esac
