#!/usr/bin/env bash
# Moodle DevOps Skill — php-info.sh
#
# Reports the PHP runtime configuration of the moodle container, focused on
# the values that matter for Moodle: version, extensions, ini limits.
#
# Read-only.
#
# Env vars read:
#   MOODLE_HOST          — pod-internal hostname of moodle container
#   CLOUVE_OPS_PASSWORD  — for sshpass -e
#
# Exit codes:
#   0 — info gathered successfully
#   1 — required env missing
#   2 — SSH or php call failed

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help]

Reports the PHP runtime config of the Moodle container — version, extensions,
ini limits relevant to Moodle. Read-only.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage; exit 0
fi

: "${MOODLE_HOST:?MOODLE_HOST not set}"
: "${CLOUVE_OPS_PASSWORD:?CLOUVE_OPS_PASSWORD not set}"

ssh_opts=(-o StrictHostKeyChecking=accept-new -o BatchMode=no -o ConnectTimeout=10)

ssh_run() {
    SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" \
        "clouve-ops@${MOODLE_HOST}" "$1"
}

echo "PHP runtime on ${MOODLE_HOST}"
echo "==============================="
echo

echo "--- Version ---"
ssh_run 'php -v 2>&1' | head -3 || { echo "ERROR: php -v failed" >&2; exit 2; }
echo

echo "--- ini limits (relevant subset) ---"
ssh_run 'php -r "
\$keys = [
    \"memory_limit\", \"post_max_size\", \"upload_max_filesize\", \"max_input_vars\",
    \"max_execution_time\", \"max_input_time\", \"max_file_uploads\",
    \"date.timezone\", \"opcache.enable\", \"opcache.memory_consumption\",
    \"opcache.max_accelerated_files\", \"opcache.validate_timestamps\",
    \"session.gc_maxlifetime\", \"display_errors\", \"log_errors\", \"error_log\",
    \"file_uploads\", \"allow_url_fopen\", \"register_argc_argv\",
];
foreach (\$keys as \$k) {
    printf(\"%-30s %s\n\", \$k, ini_get(\$k));
}
"'
echo

echo "--- Extensions Moodle needs ---"
required="iconv mbstring curl openssl ctype zip zlib gd simplexml spl pcre dom"
recommended="tokenizer soap intl exif fileinfo opcache"
ssh_run "php -r '
\$loaded = get_loaded_extensions();
echo \"# REQUIRED (5.2):\n\";
foreach ([\"$required\"] as \$line) {
    foreach (preg_split(\"/\\s+/\", \$line) as \$ext) {
        if (\$ext === \"\") continue;
        printf(\"  %-12s %s\n\", \$ext, in_array(\$ext, \$loaded) ? \"OK\" : \"MISSING\");
    }
}
echo \"# RECOMMENDED:\n\";
foreach ([\"$recommended\"] as \$line) {
    foreach (preg_split(\"/\\s+/\", \$line) as \$ext) {
        if (\$ext === \"\") continue;
        printf(\"  %-12s %s\n\", \$ext, in_array(\$ext, \$loaded) ? \"OK\" : \"MISSING\");
    }
}
'"
echo

echo "--- Database client extensions ---"
ssh_run 'php -r "
\$drivers = [];
if (extension_loaded(\"mysqli\")) \$drivers[] = \"mysqli\";
if (extension_loaded(\"pdo_mysql\")) \$drivers[] = \"pdo_mysql\";
if (extension_loaded(\"pgsql\")) \$drivers[] = \"pgsql\";
if (extension_loaded(\"pdo_pgsql\")) \$drivers[] = \"pdo_pgsql\";
if (extension_loaded(\"sqlsrv\")) \$drivers[] = \"sqlsrv\";
echo (empty(\$drivers) ? \"(none — Moodle will not be able to talk to the DB)\" : implode(\", \", \$drivers)), PHP_EOL;
"'
echo

echo "--- Moodle code version (from public/version.php) ---"
ssh_run 'sudo -u www-data php -r "require \"/var/www/html/config.php\"; echo \"version=\", \$CFG->version, \"  release=\", \$CFG->release, PHP_EOL;"' \
    || echo "ERROR: could not read version" >&2

exit 0
