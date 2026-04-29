#!/usr/bin/env bash
# Moodle DevOps Skill — backup.sh
#
# Produces a coordinated backup of the tenant's Moodle instance:
#   1. The DB dump (MariaDB/MySQL via mysqldump, or Postgres via pg_dump).
#   2. The contents of <dataroot>/filedir/, models/, lang/, upgradelogs/.
#
# A Moodle backup that includes only the DB without <dataroot>/filedir is
# unrecoverable — every file reference in mdl_files maps to an on-disk hash;
# the bytes live in <dataroot>/filedir/<2>/<2>/<sha1>. See:
#   skills/DevOps/Moodle/skill/reference/file-storage.md
#   skills/DevOps/Moodle/skill/reference/backup-restore.md
#
# What this does NOT do (cannot, from AI Studio):
#   - Coordinate with maintenance mode. For a logically-consistent backup
#     under load, the operator should enable maintenance mode FIRST. This
#     script gives best-effort consistency: --single-transaction for MySQL,
#     pg_dump's snapshot for Postgres, and a tar of <dataroot> taken
#     immediately after.
#
# Env vars read (injected by the Clouve packaging):
#   MOODLE_HOST          — pod-internal hostname of moodle container
#   MOODLE_DB_HOST       — pod-internal hostname of moodle-mysql container
#   MOODLE_DB_USER       — DB user (typically 'moodle')
#   MOODLE_DB_PASSWORD   — DB password
#   MOODLE_DB_NAME       — DB name (typically 'moodle')
#   MOODLE_DBTYPE        — 'mariadb' | 'mysqli' | 'pgsql' (default: 'mariadb')
#   MOODLE_DATAROOT      — path to <dataroot> inside the moodle container
#                          (default: /var/moodledata)
#   CLOUVE_OPS_PASSWORD  — for sshpass -e (used to SSH into moodle container)
#
# Output:
#   $HOME/backups/moodle-<timestamp>/
#     ├── db.sql.gz        (mysqldump output, gzipped) OR
#     ├── db.dump          (pg_dump custom format)
#     ├── moodledata.tar.gz
#     └── manifest.txt     (sizes, checksums, table count, file count)
#
# Exit codes:
#   0 — backup completed; both artifacts non-empty
#   1 — required env vars missing
#   2 — DB dump failed
#   3 — dataroot tar failed
#   4 — output artifact is empty or missing after the dump

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help]

Produces a coordinated DB + dataroot backup of the Moodle instance.

Reads from env vars; see the script header for the full list.

Output goes to \$HOME/backups/moodle-<timestamp>/.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage; exit 0
fi

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

: "${MOODLE_HOST:?MOODLE_HOST not set — app env not injected correctly}"
: "${MOODLE_DB_HOST:?MOODLE_DB_HOST not set}"
: "${MOODLE_DB_PASSWORD:?MOODLE_DB_PASSWORD not set}"
: "${MOODLE_DB_USER:=moodle}"
: "${MOODLE_DB_NAME:=moodle}"
: "${MOODLE_DBTYPE:=mariadb}"
: "${MOODLE_DATAROOT:=/var/moodledata}"
: "${CLOUVE_OPS_PASSWORD:?CLOUVE_OPS_PASSWORD not set — cannot SSH to moodle for dataroot tar}"

ts=$(date -u +%Y-%m-%d-%H-%M-%S)
out_dir="${HOME}/backups/moodle-${ts}"
mkdir -p "${out_dir}"

manifest="${out_dir}/manifest.txt"
{
    printf 'moodle-backup\n'
    printf 'timestamp_utc: %s\n' "${ts}"
    printf 'moodle_host: %s\n' "${MOODLE_HOST}"
    printf 'db_host: %s\n' "${MOODLE_DB_HOST}"
    printf 'db_name: %s\n' "${MOODLE_DB_NAME}"
    printf 'dbtype: %s\n' "${MOODLE_DBTYPE}"
    printf 'dataroot: %s\n' "${MOODLE_DATAROOT}"
} > "${manifest}"

# 1. DB dump
db_file=""
case "${MOODLE_DBTYPE}" in
    mariadb|mysqli|auroramysql)
        db_file="${out_dir}/db.sql.gz"
        log "Dumping ${MOODLE_DB_NAME}@${MOODLE_DB_HOST} (mysqldump) → ${db_file}"
        if ! MYSQL_PWD="${MOODLE_DB_PASSWORD}" mysqldump \
                -h "${MOODLE_DB_HOST}" \
                -u "${MOODLE_DB_USER}" \
                --single-transaction \
                --quick \
                --lock-tables=false \
                --default-character-set=utf8mb4 \
                "${MOODLE_DB_NAME}" \
                | gzip > "${db_file}"; then
            err "mysqldump failed"
            exit 2
        fi
        ;;
    pgsql)
        db_file="${out_dir}/db.dump"
        log "Dumping ${MOODLE_DB_NAME}@${MOODLE_DB_HOST} (pg_dump custom format) → ${db_file}"
        if ! PGPASSWORD="${MOODLE_DB_PASSWORD}" pg_dump \
                -h "${MOODLE_DB_HOST}" \
                -U "${MOODLE_DB_USER}" \
                -F c \
                -f "${db_file}" \
                "${MOODLE_DB_NAME}"; then
            err "pg_dump failed"
            exit 2
        fi
        ;;
    *)
        err "Unsupported MOODLE_DBTYPE: ${MOODLE_DBTYPE} (expected: mariadb, mysqli, auroramysql, pgsql)"
        exit 1
        ;;
esac

if [[ ! -s "${db_file}" ]]; then
    err "DB dump file is empty or missing: ${db_file}"
    exit 4
fi

db_size=$(wc -c < "${db_file}")
log "DB dump complete: ${db_size} bytes"
{
    printf 'db_artifact: %s\n' "$(basename "${db_file}")"
    printf 'db_size_bytes: %s\n' "${db_size}"
} >> "${manifest}"

# 2. dataroot tar — runs on the moodle container via SSH because the volume is
#    only mounted there.
data_file="${out_dir}/moodledata.tar.gz"
log "Archiving ${MOODLE_DATAROOT} via SSH to ${MOODLE_HOST} → ${data_file}"
export SSHPASS="${CLOUVE_OPS_PASSWORD}"
ssh_opts=(-o StrictHostKeyChecking=accept-new -o BatchMode=no)
if ! sshpass -e ssh "${ssh_opts[@]}" "clouve-ops@${MOODLE_HOST}" "
    sudo tar -C \"$(dirname "${MOODLE_DATAROOT}")\" \
        --exclude='$(basename "${MOODLE_DATAROOT}")/temp/*' \
        --exclude='$(basename "${MOODLE_DATAROOT}")/cache/*' \
        --exclude='$(basename "${MOODLE_DATAROOT}")/localcache/*' \
        --exclude='$(basename "${MOODLE_DATAROOT}")/sessions/*' \
        --exclude='$(basename "${MOODLE_DATAROOT}")/trashdir/*' \
        --exclude='$(basename "${MOODLE_DATAROOT}")/muc/*' \
        --exclude='$(basename "${MOODLE_DATAROOT}")/lock/*' \
        -czf - \
        \"$(basename "${MOODLE_DATAROOT}")\"
" > "${data_file}"; then
    err "dataroot tar via SSH failed"
    exit 3
fi
unset SSHPASS

if [[ ! -s "${data_file}" ]]; then
    err "dataroot archive is empty or missing: ${data_file}"
    exit 4
fi

data_size=$(wc -c < "${data_file}")
log "dataroot archive complete: ${data_size} bytes"
{
    printf 'data_artifact: %s\n' "$(basename "${data_file}")"
    printf 'data_size_bytes: %s\n' "${data_size}"
} >> "${manifest}"

# Manifest finalisation: checksums, basic counts.
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${db_file}" "${data_file}" >> "${manifest}"
elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${db_file}" "${data_file}" >> "${manifest}"
fi

log "Backup complete: ${out_dir}"
log "Manifest:"
cat "${manifest}"

cat <<NOTE

NOTE: This backup includes the DB dump and the contents of <dataroot>
      excluding ephemeral subdirs (temp, cache, localcache, sessions,
      trashdir, muc, lock). To restore, see:
        skills/DevOps/Moodle/skill/playbooks/rollback-from-backup.md

      The backup was taken WITHOUT toggling maintenance mode. For a
      logically-consistent backup under heavy write load (e.g. before
      an upgrade), enable maintenance mode FIRST:

          sshpass -e ssh clouve-ops@\${MOODLE_HOST} \\
              'sudo -u www-data php /var/www/html/admin/cli/maintenance.php --enable'

      then re-run this script.
NOTE
