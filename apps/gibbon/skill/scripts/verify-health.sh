#!/bin/bash
# Gibbon DevOps Skill — verify-health.sh
#
# Non-destructive health check. Runs the six checks the skill uses to answer
# "is Gibbon healthy?" and prints a short pass/fail per check. Exits non-zero
# if any check fails, so the skill can chain this after a playbook step.
#
# Env vars read:
#   GIBBON_HOST, GIBBON_DB_HOST, GIBBON_DB_USER, GIBBON_DB_PASSWORD, GIBBON_DB_NAME
#
# What it does NOT check (needs ops / tenant-side inspection):
#   - `service cron status` inside the gibbon container
#   - /var/log/apache2/error.log
#   - /var/log/gibbon-cron.log
# It prints reminders to check those manually.

set -u

: "${GIBBON_HOST:=gibbon}"
: "${GIBBON_DB_HOST:?GIBBON_DB_HOST not set}"
: "${GIBBON_DB_USER:=gibbon}"
: "${GIBBON_DB_PASSWORD:?GIBBON_DB_PASSWORD not set}"
: "${GIBBON_DB_NAME:=gibbon}"

pass=0
fail=0

check() {
  local label="$1"
  local ok="$2"
  if [ "$ok" = "pass" ]; then
    printf "  \u2713 %s\n" "$label"
    pass=$((pass + 1))
  else
    printf "  \u2717 %s\n" "$label"
    fail=$((fail + 1))
  fi
}

echo "Gibbon health check @ $(date +%H:%M:%S)"
echo

# 1. HTTP reachability
status=$(curl -s -o /dev/null -w "%{http_code}" "http://${GIBBON_HOST}/index.php")
if [ "$status" = "200" ]; then
  check "HTTP /index.php returns 200 (got $status)" pass
else
  check "HTTP /index.php returns 200 (got $status)" fail
fi

# 2. DB reachable
if MYSQL_PWD="${GIBBON_DB_PASSWORD}" mysqladmin \
     -h "${GIBBON_DB_HOST}" -u "${GIBBON_DB_USER}" --skip-ssl ping >/dev/null 2>&1; then
  check "MySQL ping responds on ${GIBBON_DB_HOST}" pass
else
  check "MySQL ping responds on ${GIBBON_DB_HOST}" fail
fi

# 3. gibbonSetting(version) retrievable, and record it
db_version=$(MYSQL_PWD="${GIBBON_DB_PASSWORD}" mysql \
  -h "${GIBBON_DB_HOST}" -u "${GIBBON_DB_USER}" "${GIBBON_DB_NAME}" --skip-ssl -sN -e \
  "SELECT value FROM gibbonSetting WHERE scope='System' AND name='version';" 2>/dev/null)
if [ -n "$db_version" ]; then
  check "gibbonSetting(version) = ${db_version}" pass
else
  check "gibbonSetting(version) retrievable" fail
fi

# 4. absoluteURL setting retrievable
abs_url=$(MYSQL_PWD="${GIBBON_DB_PASSWORD}" mysql \
  -h "${GIBBON_DB_HOST}" -u "${GIBBON_DB_USER}" "${GIBBON_DB_NAME}" --skip-ssl -sN -e \
  "SELECT value FROM gibbonSetting WHERE scope='System' AND name='absoluteURL';" 2>/dev/null)
if [ -n "$abs_url" ]; then
  check "absoluteURL = ${abs_url}" pass
else
  check "absoluteURL retrievable" fail
fi

# 5. Exactly one current school year
current_year_count=$(MYSQL_PWD="${GIBBON_DB_PASSWORD}" mysql \
  -h "${GIBBON_DB_HOST}" -u "${GIBBON_DB_USER}" "${GIBBON_DB_NAME}" --skip-ssl -sN -e \
  "SELECT COUNT(*) FROM gibbonSchoolYear WHERE status='Current';" 2>/dev/null)
if [ "$current_year_count" = "1" ]; then
  check "exactly one gibbonSchoolYear is Current" pass
else
  check "exactly one gibbonSchoolYear is Current (found ${current_year_count})" fail
fi

# 6. gibbonLog activity — if the last log entry is >24h old, something's wrong
last_log_age=$(MYSQL_PWD="${GIBBON_DB_PASSWORD}" mysql \
  -h "${GIBBON_DB_HOST}" -u "${GIBBON_DB_USER}" "${GIBBON_DB_NAME}" --skip-ssl -sN -e \
  "SELECT TIMESTAMPDIFF(HOUR, MAX(timestamp), NOW()) FROM gibbonLog;" 2>/dev/null)
if [ -n "$last_log_age" ] && [ "$last_log_age" -lt 24 ] 2>/dev/null; then
  check "gibbonLog has activity within last 24h (last: ${last_log_age}h ago)" pass
else
  check "gibbonLog has activity within last 24h (last: ${last_log_age}h ago)" fail
fi

unset MYSQL_PWD

echo
echo "${pass} passed, ${fail} failed"
echo
echo "Not checked from AI Studio (requires tenant / ops inspection inside the gibbon container):"
echo "  - 'service cron status'"
echo "  - /var/log/apache2/error.log"
echo "  - /var/log/gibbon-cron.log"
echo "  - File permissions on /var/www/html/uploads/"

if [ $fail -gt 0 ]; then
  exit 1
fi
exit 0
