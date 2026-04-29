#!/bin/bash
# Gibbon DevOps Skill — backup.sh
#
# Produces a DB dump of the tenant's Gibbon database, writes it to
# $HOME/backups/gibbon-<timestamp>/. This is the ONLY destructive-adjacent
# script the skill uses — it does not delete anything, but it can fill disk
# on repeated runs, so it lives behind an explicit invocation.
#
# What this does NOT do (cannot, from AI Studio):
#   - Back up /var/www/html/ on the gibbon container's gibbondata volume.
#   - Back up customAssets/ on the same.
#   - Back up config.php on the same.
# For those, escalate to Clouve ops for a volume snapshot, OR use Gibbon's
# admin UI "System Backup" feature if the tenant's version has one.
#
# Env vars read (injected by the app via containerReference/applicationUrl types):
#   GIBBON_DB_HOST        — hostname of gibbon-mysql (pod-internal)
#   GIBBON_DB_USER        — DB user (usually 'gibbon')
#   GIBBON_DB_PASSWORD    — DB password
#   GIBBON_DB_NAME        — DB name (usually 'gibbon')
#
# Exit codes:
#   0 — backup completed, dump file is non-empty
#   1 — required env vars missing
#   2 — mysqldump failed
#   3 — output file is empty or missing after dump

set -u

: "${GIBBON_DB_HOST:?GIBBON_DB_HOST not set — app env not injected correctly}"
: "${GIBBON_DB_USER:=gibbon}"
: "${GIBBON_DB_PASSWORD:?GIBBON_DB_PASSWORD not set}"
: "${GIBBON_DB_NAME:=gibbon}"

timestamp=$(date +%Y-%m-%d-%H-%M-%S)
out_dir="${HOME}/backups/gibbon-${timestamp}"
out_file="${out_dir}/gibbon.sql"

mkdir -p "${out_dir}"

echo "Backing up ${GIBBON_DB_NAME}@${GIBBON_DB_HOST} to ${out_file} ..."

MYSQL_PWD="${GIBBON_DB_PASSWORD}" mysqldump \
  -h "${GIBBON_DB_HOST}" \
  -u "${GIBBON_DB_USER}" \
  --single-transaction \
  --quick \
  --lock-tables=false \
  --default-character-set=utf8mb3 \
  --skip-ssl \
  "${GIBBON_DB_NAME}" \
  > "${out_file}"

rc=$?
unset MYSQL_PWD

if [ $rc -ne 0 ]; then
  echo "ERROR: mysqldump exited with code $rc" >&2
  exit 2
fi

if [ ! -s "${out_file}" ]; then
  echo "ERROR: dump file is empty or missing: ${out_file}" >&2
  exit 3
fi

size=$(wc -c < "${out_file}")
tables=$(grep -c '^CREATE TABLE' "${out_file}" || true)

echo "Backup complete."
echo "  Path:     ${out_file}"
echo "  Size:     ${size} bytes"
echo "  Tables:   ${tables}"
echo
echo "NOTE: this is a DB-only backup. For a complete backup that includes"
echo "      /var/www/html/uploads/, /var/www/html/config.php, and"
echo "      /var/www/html/customAssets/, request a volume snapshot of"
echo "      'gibbondata' from Clouve ops, or export via Gibbon's admin UI."
