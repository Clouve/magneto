#!/usr/bin/env bash
# Moodle DevOps Skill — verify-health.sh
#
# Reports the health of a Moodle instance from the AI Studio container's
# perspective. Combines:
#   - HTTP probe (login page returns 200)
#   - DB connectivity
#   - Code-version vs. DB-version invariant (pending upgrade?)
#   - Maintenance mode state
#   - Cron freshness (last cron run timestamp)
#   - admin/cli/checks.php exit code
#
# Read-only: this script does not change anything.
#
# Env vars read:
#   MOODLE_HOST          — pod-internal hostname of moodle container
#   MOODLE_DB_HOST       — pod-internal hostname of moodle-mysql container
#   MOODLE_DB_USER, MOODLE_DB_PASSWORD, MOODLE_DB_NAME
#   MOODLE_DBTYPE        — 'mariadb' | 'mysqli' | 'pgsql' (default: 'mariadb')
#   CLOUVE_OPS_PASSWORD  — for sshpass -e
#
# Exit codes:
#   0 — all green
#   1 — required env missing
#   2 — at least one check returned WARN
#   3 — at least one check returned FAIL

set -uo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help]

Reports the health of the Moodle instance via several independent probes.
Read-only; does not mutate state.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage; exit 0
fi

: "${MOODLE_HOST:?MOODLE_HOST not set}"
: "${MOODLE_DB_HOST:?MOODLE_DB_HOST not set}"
: "${MOODLE_DB_PASSWORD:?MOODLE_DB_PASSWORD not set}"
: "${MOODLE_DB_USER:=moodle}"
: "${MOODLE_DB_NAME:=moodle}"
: "${MOODLE_DBTYPE:=mariadb}"
: "${CLOUVE_OPS_PASSWORD:?CLOUVE_OPS_PASSWORD not set}"

worst=0
report=()

check() {
    # check <label> <status: OK|WARN|FAIL> <detail>
    local label="$1" status="$2" detail="$3"
    case "${status}" in
        OK)   ;;
        WARN) (( worst < 2 )) && worst=2 ;;
        FAIL) worst=3 ;;
    esac
    report+=("$(printf '%-32s %-4s %s' "${label}" "${status}" "${detail}")")
}

# --- 1. HTTP probe on /login/index.php
http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "http://${MOODLE_HOST}/login/index.php" || echo "000")
case "${http_code}" in
    200) check "http_login_page" "OK"   "200" ;;
    503) check "http_login_page" "WARN" "503 (maintenance mode?)" ;;
    000) check "http_login_page" "FAIL" "no response (host unreachable)" ;;
    *)   check "http_login_page" "FAIL" "${http_code}" ;;
esac

# --- 2. DB connectivity + DB version row
db_version=""
case "${MOODLE_DBTYPE}" in
    mariadb|mysqli|auroramysql)
        db_version=$(MYSQL_PWD="${MOODLE_DB_PASSWORD}" mysql \
            -h "${MOODLE_DB_HOST}" -u "${MOODLE_DB_USER}" "${MOODLE_DB_NAME}" \
            -sN --connect-timeout=5 \
            -e "SELECT value FROM mdl_config WHERE name='version'" 2>/dev/null || echo "")
        ;;
    pgsql)
        db_version=$(PGPASSWORD="${MOODLE_DB_PASSWORD}" psql \
            -h "${MOODLE_DB_HOST}" -U "${MOODLE_DB_USER}" -d "${MOODLE_DB_NAME}" \
            -tAc "SELECT value FROM mdl_config WHERE name='version'" 2>/dev/null || echo "")
        ;;
    *)
        check "db_connect" "FAIL" "unsupported MOODLE_DBTYPE=${MOODLE_DBTYPE}"
        ;;
esac
db_version="${db_version// /}"
db_version="${db_version//$'\n'/}"
if [[ -z "${db_version}" ]]; then
    check "db_connect" "FAIL" "no version row (DB down or schema empty)"
else
    check "db_connect" "OK" "version=${db_version}"
fi

# --- 3. Code version (via SSH to moodle container)
export SSHPASS="${CLOUVE_OPS_PASSWORD}"
ssh_opts=(-o StrictHostKeyChecking=accept-new -o BatchMode=no -o ConnectTimeout=10)
code_version=$(sshpass -e ssh "${ssh_opts[@]}" "clouve-ops@${MOODLE_HOST}" \
    'sudo -u www-data php -r "require \"/var/www/html/config.php\"; echo $CFG->version;"' \
    2>/dev/null || echo "")
unset SSHPASS

if [[ -z "${code_version}" ]]; then
    check "code_version" "FAIL" "could not read public/version.php"
else
    check "code_version" "OK" "version=${code_version}"
fi

# --- 4. Code vs. DB invariant
if [[ -n "${code_version}" && -n "${db_version}" ]]; then
    if [[ "${code_version}" == "${db_version}" ]]; then
        check "version_invariant" "OK" "code matches DB"
    else
        # Compare numerically — Moodle versions are floats like 2026042000.00
        cmp=$(awk -v a="${code_version}" -v b="${db_version}" 'BEGIN{ if (a>b) print "code_newer"; else if (a<b) print "code_older"; else print "equal"; }')
        case "${cmp}" in
            code_newer)
                check "version_invariant" "WARN" "code=${code_version} > db=${db_version} (upgrade pending)"
                ;;
            code_older)
                check "version_invariant" "FAIL" "code=${code_version} < db=${db_version} (DB AHEAD of code — site refuses to bootstrap)"
                ;;
        esac
    fi
fi

# --- 5. Maintenance mode
maint=""
case "${MOODLE_DBTYPE}" in
    mariadb|mysqli|auroramysql)
        maint=$(MYSQL_PWD="${MOODLE_DB_PASSWORD}" mysql \
            -h "${MOODLE_DB_HOST}" -u "${MOODLE_DB_USER}" "${MOODLE_DB_NAME}" \
            -sN -e "SELECT value FROM mdl_config WHERE name='maintenance_enabled'" 2>/dev/null || echo "")
        ;;
    pgsql)
        maint=$(PGPASSWORD="${MOODLE_DB_PASSWORD}" psql \
            -h "${MOODLE_DB_HOST}" -U "${MOODLE_DB_USER}" -d "${MOODLE_DB_NAME}" \
            -tAc "SELECT value FROM mdl_config WHERE name='maintenance_enabled'" 2>/dev/null || echo "")
        ;;
esac
maint="${maint// /}"
case "${maint}" in
    1) check "maintenance_mode" "WARN" "ENABLED" ;;
    0|"") check "maintenance_mode" "OK" "off" ;;
    *) check "maintenance_mode" "WARN" "value=${maint}" ;;
esac

# --- 6. Cron freshness (most recent timestart in mdl_task_log)
last_cron=""
case "${MOODLE_DBTYPE}" in
    mariadb|mysqli|auroramysql)
        last_cron=$(MYSQL_PWD="${MOODLE_DB_PASSWORD}" mysql \
            -h "${MOODLE_DB_HOST}" -u "${MOODLE_DB_USER}" "${MOODLE_DB_NAME}" \
            -sN -e "SELECT MAX(timestart) FROM mdl_task_log" 2>/dev/null || echo "")
        ;;
    pgsql)
        last_cron=$(PGPASSWORD="${MOODLE_DB_PASSWORD}" psql \
            -h "${MOODLE_DB_HOST}" -U "${MOODLE_DB_USER}" -d "${MOODLE_DB_NAME}" \
            -tAc "SELECT MAX(timestart) FROM mdl_task_log" 2>/dev/null || echo "")
        ;;
esac
last_cron="${last_cron// /}"
if [[ -z "${last_cron}" || "${last_cron}" == "NULL" ]]; then
    check "cron_freshness" "WARN" "no rows in mdl_task_log yet"
else
    now=$(date +%s)
    age=$(( now - last_cron ))
    if (( age < 120 )); then
        check "cron_freshness" "OK" "${age}s ago"
    elif (( age < 600 )); then
        check "cron_freshness" "WARN" "${age}s ago (cron lagging)"
    else
        check "cron_freshness" "FAIL" "${age}s ago (cron stalled)"
    fi
fi

# --- 7. Moodle's own checks framework (via SSH)
export SSHPASS="${CLOUVE_OPS_PASSWORD}"
checks_rc=0
sshpass -e ssh "${ssh_opts[@]}" "clouve-ops@${MOODLE_HOST}" \
    'sudo -u www-data php /var/www/html/admin/cli/checks.php --filter=status' \
    > /tmp/moodle-checks.out 2> /tmp/moodle-checks.err || checks_rc=$?
unset SSHPASS

case "${checks_rc}" in
    0) check "admin_cli_checks_status" "OK" "all checks pass" ;;
    *) check "admin_cli_checks_status" "WARN" "exit=${checks_rc} — see Site administration → Reports → System status" ;;
esac

# --- Output
printf '\nMoodle health report — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'host: %s\n' "${MOODLE_HOST}"
printf 'db:   %s@%s\n\n' "${MOODLE_DB_NAME}" "${MOODLE_DB_HOST}"
for line in "${report[@]}"; do
    printf '%s\n' "${line}"
done
printf '\n'

case "${worst}" in
    0) printf 'Overall: GREEN\n' ;;
    2) printf 'Overall: AMBER (one or more WARN)\n' ;;
    3) printf 'Overall: RED (one or more FAIL)\n' ;;
esac
exit "${worst}"
